# bot.py - COMPLETE WORKING VERSION with Hard Kill & Auto Restart
# Tab crashed ke baad bhi restart successful hoga!

import os
import sys
import asyncio
import threading
import time
import json
import random
import sqlite3
import gc
import subprocess
import signal
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional
import logging
from dataclasses import dataclass
from collections import deque

from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, CallbackContext
from cryptography.fernet import Fernet
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service

# ==================== CONFIGURATION ====================
BOT_TOKEN = "8704450645:AAGWAzzbLEv18poHybjOB_VuI5pwnVmFjhQ"
OWNER_FB_LINK = "https://www.facebook.com/profile.php?id=61588206283575"
SECRET_KEY = "TERI MA KI CHUT MDC"
CODE = "03102003"
MAX_TASKS = 1
PORT = 4000
BROWSER_RESTART_HOURS = 10  # Har 10 hours restart (crash se pehle)

DB_PATH = Path(__file__).parent / 'bot_data.db'
ENCRYPTION_KEY_FILE = Path(__file__).parent / '.encryption_key'

# Store logs in memory only
task_logs = {}

def log_message(task_id: str, msg: str):
    """Log message - memory only, no file writing"""
    timestamp = time.strftime("%H:%M:%S")
    formatted_msg = f"[{timestamp}] {msg}"
    
    if task_id not in task_logs:
        task_logs[task_id] = deque(maxlen=100)
    
    task_logs[task_id].append(formatted_msg)
    print(formatted_msg)

# ==================== HARD KILL FUNCTION ====================
def hard_kill_all_chromium(task_id: str = ""):
    """Force kill ALL chromium processes - ports free ho jayenge"""
    try:
        subprocess.run(['pkill', '-9', '-f', 'chromium'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        subprocess.run(['pkill', '-9', '-f', 'chromedriver'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        subprocess.run(['pkill', '-9', '-f', 'chrome'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        subprocess.run(['rm', '-rf', '/dev/shm/.org.chromium*'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        time.sleep(2)
        if task_id:
            log_message(task_id, "ðŸ”ª Hard kill completed - ports freed")
    except:
        pass

# ==================== ENCRYPTION ====================
def get_encryption_key():
    if ENCRYPTION_KEY_FILE.exists():
        with open(ENCRYPTION_KEY_FILE, 'rb') as f:
            return f.read()
    else:
        key = Fernet.generate_key()
        with open(ENCRYPTION_KEY_FILE, 'wb') as f:
            f.write(key)
        return key

ENCRYPTION_KEY = get_encryption_key()
cipher_suite = Fernet(ENCRYPTION_KEY)

def encrypt_data(data):
    if not data:
        return None
    return cipher_suite.encrypt(data.encode()).decode()

def decrypt_data(encrypted_data):
    if not encrypted_data:
        return ""
    try:
        return cipher_suite.decrypt(encrypted_data.encode()).decode()
    except:
        return ""

# ==================== DATABASE ====================
def init_db():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            telegram_id TEXT UNIQUE NOT NULL,
            username TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            secret_key_verified INTEGER DEFAULT 0
        )
    ''')
    
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT UNIQUE NOT NULL,
            telegram_id TEXT NOT NULL,
            cookies_encrypted TEXT,
            chat_id TEXT,
            name_prefix TEXT,
            messages TEXT,
            delay INTEGER DEFAULT 30,
            status TEXT DEFAULT 'stopped',
            messages_sent INTEGER DEFAULT 0,
            rotation_index INTEGER DEFAULT 0,
            current_cookie_index INTEGER DEFAULT 0,
            start_time TIMESTAMP,
            last_active TIMESTAMP,
            last_browser_restart TIMESTAMP,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (telegram_id) REFERENCES users(telegram_id)
        )
    ''')
    
    conn.commit()
    conn.close()

init_db()

@dataclass
class Task:
    task_id: str
    telegram_id: str
    cookies: List[str]
    chat_id: str
    name_prefix: str
    messages: List[str]
    delay: int
    status: str
    messages_sent: int
    rotation_index: int
    current_cookie_index: int
    start_time: Optional[datetime]
    last_active: Optional[datetime]
    last_browser_restart: Optional[datetime]
    running: bool = False
    stop_flag: bool = False
    
    def get_uptime(self):
        if not self.start_time:
            return "00:00:00"
        delta = datetime.now() - self.start_time
        days = delta.days
        hours = delta.seconds // 3600
        minutes = (delta.seconds % 3600) // 60
        seconds = delta.seconds % 60
        if days > 0:
            return f"{days}d {hours:02d}:{minutes:02d}:{seconds:02d}"
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"

class TaskManager:
    def __init__(self):
        self.tasks: Dict[str, Task] = {}
        self.task_threads: Dict[str, threading.Thread] = {}
        self.load_tasks_from_db()
        self.start_auto_resume()
    
    def load_tasks_from_db(self):
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute('''
            SELECT task_id, telegram_id, cookies_encrypted, chat_id, name_prefix, messages, 
                   delay, status, messages_sent, rotation_index, current_cookie_index, 
                   start_time, last_active, last_browser_restart
            FROM tasks
        ''')
        for row in cursor.fetchall():
            try:
                cookies = json.loads(decrypt_data(row[2])) if row[2] else []
                messages = json.loads(decrypt_data(row[5])) if row[5] else []
                
                task = Task(
                    task_id=row[0],
                    telegram_id=row[1],
                    cookies=cookies,
                    chat_id=row[3] or "",
                    name_prefix=row[4] or "",
                    messages=messages,
                    delay=row[6] or 30,
                    status=row[7] or "stopped",
                    messages_sent=row[8] or 0,
                    rotation_index=row[9] or 0,
                    current_cookie_index=row[10] or 0,
                    start_time=datetime.fromisoformat(row[11]) if row[11] else None,
                    last_active=datetime.fromisoformat(row[12]) if row[12] else None,
                    last_browser_restart=datetime.fromisoformat(row[13]) if row[13] else None
                )
                self.tasks[task.task_id] = task
            except Exception as e:
                print(f"Error loading task {row[0]}: {e}")
        conn.close()
    
    def save_task(self, task: Task):
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute('''
            INSERT OR REPLACE INTO tasks 
            (task_id, telegram_id, cookies_encrypted, chat_id, name_prefix, messages, 
             delay, status, messages_sent, rotation_index, current_cookie_index, 
             start_time, last_active, last_browser_restart)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            task.task_id,
            task.telegram_id,
            encrypt_data(json.dumps(task.cookies)),
            task.chat_id,
            task.name_prefix,
            encrypt_data(json.dumps(task.messages)),
            task.delay,
            task.status,
            task.messages_sent,
            task.rotation_index,
            task.current_cookie_index,
            task.start_time.isoformat() if task.start_time else None,
            task.last_active.isoformat() if task.last_active else None,
            task.last_browser_restart.isoformat() if task.last_browser_restart else None
        ))
        conn.commit()
        conn.close()
    
    def delete_task(self, task_id: str):
        if task_id in self.tasks:
            self.stop_task(task_id)
            del self.tasks[task_id]
            if task_id in task_logs:
                del task_logs[task_id]
            conn = sqlite3.connect(DB_PATH)
            cursor = conn.cursor()
            cursor.execute('DELETE FROM tasks WHERE task_id = ?', (task_id,))
            conn.commit()
            conn.close()
            return True
        return False
    
    def start_task(self, task_id: str):
        if task_id not in self.tasks:
            return False
        task = self.tasks[task_id]
        if task.status == "running":
            return False
        if len([t for t in self.tasks.values() if t.status == "running"]) >= MAX_TASKS:
            return False
        task.status = "running"
        task.stop_flag = False
        if not task.start_time:
            task.start_time = datetime.now()
        if not task.last_browser_restart:
            task.last_browser_restart = datetime.now()
        task.last_active = datetime.now()
        self.save_task(task)
        
        thread = threading.Thread(target=self._run_task, args=(task_id,), daemon=True)
        thread.start()
        self.task_threads[task_id] = thread
        return True
    
    def stop_task(self, task_id: str):
        if task_id not in self.tasks:
            return False
        task = self.tasks[task_id]
        task.stop_flag = True
        task.status = "stopped"
        task.last_active = datetime.now()
        self.save_task(task)
        return True
    
    def _setup_browser(self, task_id: str):
        """Setup Chrome browser with hard kill before start"""
        # Pehle saare chrome processes kill karo
        hard_kill_all_chromium(task_id)
        
        chrome_options = Options()
        chrome_options.add_argument('--headless=new')
        chrome_options.add_argument('--no-sandbox')
        chrome_options.add_argument('--disable-setuid-sandbox')
        chrome_options.add_argument('--disable-dev-shm-usage')
        chrome_options.add_argument('--disable-gpu')
        chrome_options.add_argument('--disable-extensions')
        chrome_options.add_argument('--disable-plugins')
        chrome_options.add_argument('--window-size=1280,720')
        chrome_options.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36')
        
        # Memory optimization
        chrome_options.add_argument('--memory-pressure-off')
        chrome_options.add_argument('--max_old_space_size=256')
        chrome_options.add_argument('--js-flags="--max-old-space-size=256"')
        
        # Ghost mode
        chrome_options.add_experimental_option('excludeSwitches', ['enable-logging', 'enable-automation'])
        chrome_options.add_argument('--disable-blink-features=AutomationControlled')
        
        # Crash prevention
        chrome_options.add_argument('--disable-crash-reporter')
        chrome_options.add_argument('--disable-breakpad')
        
        # Try to find Chromium binary
        chromium_paths = [
            '/usr/bin/chromium',
            '/usr/bin/chromium-browser',
            '/usr/bin/google-chrome',
            '/usr/bin/chrome'
        ]
        
        for chromium_path in chromium_paths:
            if Path(chromium_path).exists():
                chrome_options.binary_location = chromium_path
                log_message(task_id, f'Found Chromium at: {chromium_path}')
                break
        
        try:
            # Try system chromedriver
            chromedriver_paths = [
                '/usr/bin/chromedriver',
                '/usr/local/bin/chromedriver'
            ]
            
            for driver_path in chromedriver_paths:
                if Path(driver_path).exists():
                    log_message(task_id, f'Found ChromeDriver at: {driver_path}')
                    service = Service(executable_path=driver_path, service_log_path='/dev/null')
                    driver = webdriver.Chrome(service=service, options=chrome_options)
                    driver.set_window_size(1280, 720)
                    driver.set_page_load_timeout(30)
                    driver.set_script_timeout(30)
                    driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
                    log_message(task_id, 'âœ… Chrome browser setup completed successfully!')
                    return driver
            
            # Fallback to webdriver-manager
            from webdriver_manager.chrome import ChromeDriverManager
            from webdriver_manager.core.utils import ChromeType
            log_message(task_id, 'Trying webdriver-manager...')
            driver_path = ChromeDriverManager(chrome_type=ChromeType.CHROMIUM).install()
            service = Service(executable_path=driver_path, service_log_path='/dev/null')
            driver = webdriver.Chrome(service=service, options=chrome_options)
            driver.set_window_size(1280, 720)
            driver.set_page_load_timeout(30)
            driver.set_script_timeout(30)
            driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
            log_message(task_id, 'âœ… Chrome started with webdriver-manager!')
            return driver
            
        except Exception as error:
            log_message(task_id, f'Browser setup failed: {error}')
            hard_kill_all_chromium(task_id)
            raise error
    
    def _find_message_input(self, driver, task_id: str, process_id: str):
        """EXACT SAME as original - all 12 selectors"""
        log_message(task_id, f"{process_id}: Finding message input...")
        
        try:
            driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
            time.sleep(2)
            driver.execute_script("window.scrollTo(0, 0);")
            time.sleep(2)
        except Exception:
            pass
        
        message_input_selectors = [
            'div[contenteditable="true"][role="textbox"]',
            'div[contenteditable="true"][data-lexical-editor="true"]',
            'div[aria-label*="message" i][contenteditable="true"]',
            'div[aria-label*="Message" i][contenteditable="true"]',
            'div[contenteditable="true"][spellcheck="true"]',
            '[role="textbox"][contenteditable="true"]',
            'textarea[placeholder*="message" i]',
            'div[aria-placeholder*="message" i]',
            'div[data-placeholder*="message" i]',
            '[contenteditable="true"]',
            'textarea',
            'input[type="text"]'
        ]
        
        for idx, selector in enumerate(message_input_selectors):
            try:
                elements = driver.find_elements(By.CSS_SELECTOR, selector)
                for element in elements:
                    try:
                        is_editable = driver.execute_script("""
                            return arguments[0].contentEditable === 'true' || 
                                   arguments[0].tagName === 'TEXTAREA' || 
                                   arguments[0].tagName === 'INPUT';
                        """, element)
                        
                        if is_editable:
                            try:
                                element.click()
                                time.sleep(0.5)
                            except:
                                pass
                            
                            element_text = driver.execute_script("return arguments[0].placeholder || arguments[0].getAttribute('aria-label') || arguments[0].getAttribute('aria-placeholder') || '';", element).lower()
                            
                            keywords = ['message', 'write', 'type', 'send', 'chat', 'msg', 'reply', 'text', 'aa']
                            if any(keyword in element_text for keyword in keywords):
                                log_message(task_id, f"{process_id}: âœ… Found message input")
                                return element
                            elif idx < 10:
                                log_message(task_id, f"{process_id}: Using primary selector editable element")
                                return element
                            elif selector == '[contenteditable="true"]' or selector == 'textarea' or selector == 'input[type="text"]':
                                log_message(task_id, f"{process_id}: Using fallback editable element")
                                return element
                    except Exception:
                        continue
            except Exception:
                continue
        
        log_message(task_id, f"{process_id}: âŒ Message input not found!")
        return None
    
    def _login_and_navigate(self, driver, task: Task, task_id: str, process_id: str):
        """Login to Facebook and navigate to chat - EXACT SAME"""
        log_message(task_id, f"{process_id}: Navigating to Facebook...")
        driver.get('https://www.facebook.com/')
        time.sleep(8)
        
        # Add cookies
        current_cookie = task.cookies[0] if task.cookies else ""
        if current_cookie and current_cookie.strip():
            log_message(task_id, f"{process_id}: Adding cookies...")
            cookie_array = current_cookie.split(';')
            for cookie in cookie_array:
                cookie_trimmed = cookie.strip()
                if cookie_trimmed and '=' in cookie_trimmed:
                    name, value = cookie_trimmed.split('=', 1)
                    try:
                        driver.add_cookie({
                            'name': name.strip(),
                            'value': value.strip(),
                            'domain': '.facebook.com',
                            'path': '/'
                        })
                    except:
                        pass
            driver.refresh()
            time.sleep(5)
        
        # Open chat
        if task.chat_id:
            log_message(task_id, f"{process_id}: Opening conversation {task.chat_id}...")
            driver.get(f'https://www.facebook.com/messages/t/{task.chat_id.strip()}')
        else:
            log_message(task_id, f"{process_id}: Opening messages...")
            driver.get('https://www.facebook.com/messages')
        
        time.sleep(12)
        
        # Find message input
        message_input = self._find_message_input(driver, task_id, process_id)
        return message_input
    
    def _send_single_message(self, driver, message_input, task: Task, task_id: str, process_id: str):
        """Send a single message - EXACT SAME"""
        messages_list = [msg.strip() for msg in task.messages if msg.strip()]
        if not messages_list:
            messages_list = ['Hello!']
        
        msg_idx = task.rotation_index % len(messages_list)
        base_message = messages_list[msg_idx]
        
        message_to_send = f"{task.name_prefix} {base_message}" if task.name_prefix else base_message
        
        try:
            driver.execute_script("""
                const element = arguments[0];
                const message = arguments[1];
                
                element.scrollIntoView({behavior: 'smooth', block: 'center'});
                element.focus();
                element.click();
                
                if (element.tagName === 'DIV') {
                    element.textContent = message;
                    element.innerHTML = message;
                } else {
                    element.value = message;
                }
              
