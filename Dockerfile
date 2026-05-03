# bot.py - MEMORY + TIME BASED RESTART (No Message Trigger)
# Kabhi tab crash nahi hoga - memory dekh kar restart hoga

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
import psutil
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional
from dataclasses import dataclass
from collections import deque

from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, CallbackContext
from cryptography.fernet import Fernet
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.options import Options

# ==================== CONFIGURATION ====================
BOT_TOKEN = "8704450645:AAGWAzzbLEv18poHybjOB_VuI5pwnVmFjhQ"
OWNER_FB_LINK = "https://www.facebook.com/profile.php?id=61588206283575"
SECRET_KEY = "TERI MA KI CHUT MDC"
CODE = "03102003"
MAX_TASKS = 1
PORT = 4000

# Restart Settings
BROWSER_RESTART_HOURS = 10  # Backup: Har 10 hours pe restart (safety)
MEMORY_LIMIT_MB = 1000  # Agar memory 1GB se zyada hui toh restart
MEMORY_CHECK_INTERVAL = 60  # Har 60 second memory check karo

DB_PATH = Path(__file__).parent / 'bot_data.db'
ENCRYPTION_KEY_FILE = Path(__file__).parent / '.encryption_key'

# Store logs in memory only
task_logs = {}

def log_message(task_id: str, msg: str):
    timestamp = time.strftime("%H:%M:%S")
    formatted_msg = f"[{timestamp}] {msg}"
    
    if task_id not in task_logs:
        task_logs[task_id] = deque(maxlen=100)
    
    task_logs[task_id].append(formatted_msg)
    print(formatted_msg)

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

# ==================== HARD KILL FUNCTION ====================
def hard_kill_chromium(task_id: str):
    """Force kill all chromium processes"""
    try:
        subprocess.run(['pkill', '-9', '-f', 'chromium'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        subprocess.run(['pkill', '-9', '-f', 'chromedriver'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        subprocess.run(['pkill', '-9', '-f', 'chrome'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        subprocess.run(['rm', '-rf', '/dev/shm/.org.chromium*'], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        time.sleep(2)
        log_message(task_id, "ðŸ”ª Hard kill completed")
    except:
        pass

def get_chrome_memory_mb():
    """Get total memory usage of all chrome/chromium processes"""
    total_memory = 0
    try:
        for proc in psutil.process_iter(['pid', 'name', 'memory_info']):
            try:
                name = proc.info['name'].lower() if proc.info['name'] else ''
                if any(x in name for x in ['chromium', 'chrome', 'chromedriver']):
                    total_memory += proc.info['memory_info'].rss / (1024 * 1024)  # Convert to MB
            except:
                continue
    except:
        pass
    return total_memory

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

# ==================== TASK MANAGER ====================
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
        """Setup Chrome browser with memory optimization"""
        hard_kill_chromium(task_id)
        
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
        
        # Memory optimization - CRITICAL
        chrome_options.add_argument('--memory-pressure-off')
        chrome_options.add_argument('--max_old_space_size=256')
        chrome_options.add_argument('--js-flags="--max-old-space-size=256"')
        chrome_options.add_argument('--disable-software-rasterizer')
        
        # Anti-detection
        chrome_options.add_experimental_option('excludeSwitches', ['enable-logging', 'enable-automation'])
        chrome_options.add_experimental_option('useAutomationExtension', False)
        chrome_options.add_argument('--disable-blink-features=AutomationControlled')
        
        # Crash prevention
        chrome_options.add_argument('--disable-crash-reporter')
        chrome_options.add_argument('--disable-breakpad')
        
        # Find Chromium
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
        
        # Find ChromeDriver
        chromedriver_paths = [
            '/usr/bin/chromedriver',
            '/usr/local/bin/chromedriver'
        ]
        
        driver_path = None
        for driver_candidate in chromedriver_paths:
            if Path(driver_candidate).exists():
                driver_path = driver_candidate
                log_message(task_id, f'Found ChromeDriver at: {driver_path}')
                break
        
        try:
            from selenium.webdriver.chrome.service import Service
            
            os.environ['DBUS_SESSION_BUS_ADDRESS'] = '/dev/null'
            
            if driver_path:
                service = Service(executable_path=driver_path, service_log_path='/dev/null')
                driver = webdriver.Chrome(service=service, options=chrome_options)
            else:
                driver = webdriver.Chrome(options=chrome_options)
            
            driver.set_window_size(1280, 720)
            driver.set_page_load_timeout(30)
            driver.set_script_timeout(30)
            
            driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
            
            log_message(task_id, 'âœ… Chrome browser setup completed!')
            return driver
            
        except Exception as error:
            log_message(task_id, f'Browser setup failed: {error}')
            hard_kill_chromium(task_id)
            raise error
    
    def _find_message_input(self, driver, task_id: str, process_id: str):
        """Ultra fast message input detection"""
        log_message(task_id, f"{process_id}: Finding message input...")
        
        # Fastest direct selectors
        fast_selectors = [
            'div[aria-label="Message"][contenteditable="true"]',
            'div[aria-label="Write a message"][contenteditable="true"]',
            'div[aria-placeholder="Write a message"][contenteditable="true"]',
            'div[contenteditable="true"][role="textbox"]',
            'div[contenteditable="true"]:not([role="combobox"])'
        ]
        
        for selector in fast_selectors:
            try:
                element = driver.find_element(By.CSS_SELECTOR, selector)
                if element and element.is_enabled():
                    log_message(task_id, f"{process_id}: âš¡ Input found instantly!")
                    try:
                        element.click()
                    except:
                        pass
                    return element
            except:
                continue
        
        # Fallback selectors
        fallback_selectors = [
            'div[contenteditable="true"]',
            'textarea',
            '[contenteditable="true"]',
        ]
        
        for selector in fallback_selectors:
            try:
                elements = driver.find_elements(By.CSS_SELECTOR, selector)
                for element in elements:
                    try:
                        if element.is_enabled():
                            element.click()
                            log_message(task_id, f"{process_id}: âœ… Found message input")
                            return element
                    except:
                        continue
            except:
                continue
        
        log_message(task_id, f"{process_id}: âŒ Message input not found!")
        return None
    
    def _login_and_navigate(self, driver, task: Task, task_id: str, process_id: str):
        """Login and navigate to chat"""
        log_message(task_id, f"{process_id}: Navigating to Facebook...")
        driver.get('https://www.facebook.com/')
        time.sleep(5)
        
        # Add cookies
        if task.cookies and task.cookies[0]:
            log_message(task_id, f"{process_id}: Adding cookies...")
            cookie_string = task.cookies[0]
            cookie_pairs = cookie_string.split(';')
            
            for pair in cookie_pairs:
                pair = pair.strip()
                if '=' in pair:
                    name, value = pair.split('=', 1)
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
        
        # Navigate to chat
        if task.chat_id:
            log_message(task_id, f"{process_id}: Opening conversation...")
            driver.get(f'https://www.facebook.com/messages/t/{task.chat_id.strip()}')
        else:
            driver.get('https://www.facebook.com/messages')
        
        time.sleep(8)
        message_input = self._find_message_input(driver, task_id, process_id)
        return message_input
    
    def _send_single_message(self, driver, message_input, task: Task, task_id: str, process_id: str):
        """Send a single message"""
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
                element.innerText = '';
                element.textContent = '';
                
                if (element.tagName === 'DIV') {
                    element.textContent = message;
                    element.innerHTML = message;
                } else {
                    element.value = message;
                }
                
                element.dispatchEvent(new Event('input', { bubbles: true }));
                element.dispatchEvent(new Event('change', { bubbles: true }));
            """, message_input, message_to_send)
            
            time.sleep(1)
            
            # Try to send
            driver.execute_script("""
                const sendBtn = document.querySelector('[aria-label="Send"]:not([aria-label*="like"]), [data-testid="send-button"]');
                if (sendBtn && sendBtn.offsetParent !== null) {
                    sendBtn.click();
                } else {
                    const element = arguments[0];
                    const enterEvent = new KeyboardEvent('keydown', {
                        key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true
                    });
                    element.dispatchEvent(enterEvent);
                }
            """, message_input)
            
            task.messages_sent += 1
            task.rotation_index += 1
            task.last_active = datetime.now()
            self.save_task(task)
            
            log_message(task_id, f"{process_id}: ðŸ“¨ Message #{task.messages_sent} sent")
            return True
            
        except Exception as send_error:
            log_message(task_id, f"{process_id}: Send error: {str(send_error)[:100]}")
            return False
    
    def _run_task(self, task_id: str):
        """Main task runner - MEMORY + TIME based restart (NO message trigger)"""
        task = self.tasks[task_id]
        task.running = True
        process_id = f"TASK-{task_id[-6:]}"
        
        driver = None
        message_input = None
        consecutive_failures = 0
        last_memory_check = time.time()
        
        while task.status == "running" and not task.stop_flag:
            try:
                current_time = datetime.now()
                need_restart = False
                restart_reason = ""
                
                # CHECK 1: Memory-based restart (MAIN TRIGGER)
                if time.time() - last_memory_check >= MEMORY_CHECK_INTERVAL:
                    memory_mb = get_chrome_memory_mb()
                    last_memory_check = time.time()
                    
                    if memory_mb > MEMORY_LIMIT_MB:
                        need_restart = True
                        restart_reason = f"Memory high: {memory_mb:.0f}MB > {MEMORY_LIMIT_MB}MB"
                        log_message(task_id, f"{process_id}: âš ï¸ {restart_reason}")
                
                # CHECK 2: Time-based restart (BACKUP - every 8 hours)
                if task.last_browser_restart:
                    hours_since = (current_time - task.last_browser_restart).total_seconds() / 3600
                    if hours_since >= BROWSER_RESTART_HOURS:
                        need_restart = True
                        restart_reason = f"Time-based: {hours_since:.1f} hours"
                        log_message(task_id, f"{process_id}: ðŸ”„ {restart_reason}")
                
                # CHECK 3: Browser dead?
                if driver is None:
                    need_restart = True
                    restart_reason = "Browser missing"
                
                # Perform restart if needed
                if need_restart:
                    log_message(task_id, f"{process_id}: ðŸ”„ Restarting... Reason: {restart_reason}")
                    
                    # Hard kill old browser
                    if driver:
                        try:
                            driver.quit()
                        except:
                            pass
                    
                    hard_kill_chromium(task_id)
                    
                    # Create new browser with retry
                    new_driver = None
                    for retry in range(3):
                        try:
                            new_driver = self._setup_browser(task_id)
                            if new_driver:
                                break
                        except Exception as e:
                            log_message(task_id, f"{process_id}: Setup retry {retry+1}/3 failed")
                            hard_kill_chromium(task_id)
                            time.sleep(5)
                    
                    if not new_driver:
                        log_message(task_id, f"{process_id}: âŒ Failed to setup browser!")
                        time.sleep(30)
                        continue
                    
                    driver = new_driver
                    
                    # Login and navigate with retry
                    for retry in range(3):
                        message_input = self._login_and_navigate(driver, task, task_id, process_id)
                        if message_input:
                            break
                        log_message(task_id, f"{process_id}: Navigate retry {retry+1}/3...")
                        time.sleep(5)
                    
                    if not message_input:
                        log_message(task_id, f"{process_id}: âŒ Failed to find message input!")
                        driver = None
                        hard_kill_chromium(task_id)
                        time.sleep(15)
                        continue
                    
                    # Update restart tracking
                    task.last_browser_restart = datetime.now()
                    self.save_task(task)
                    
                    log_message(task_id, f"{process_id}: âœ… Browser ready! Memory: {get_chrome_memory_mb():.0f}MB")
                    log_message(task_id, f"{process_id}: ðŸ“ Resuming from message #{task.messages_sent + 1}")
                    consecutive_failures = 0
                    time.sleep(5)
                    continue  # Skip message send this cycle, let browser settle
                
                # Verify message input is still valid
                try:
                    if message_input:
                        message_input.is_enabled()
                    else:
                        raise Exception("Input lost")
                except:
                    log_message(task_id, f"{process_id}: Input lost, reconnecting...")
                    message_input = self._login_and_navigate(driver, task, task_id, process_id)
                    if not message_input:
                        driver = None
                        time.sleep(5)
                        continue
                
                # Send message
                success = self._send_single_message(driver, message_input, task, task_id, process_id)
                
                if success:
                    consecutive_failures = 0
                    # Random delay to avoid detection
                    actual_delay = task.delay * random.uniform(0.85, 1.15)
                    time.sleep(actual_delay)
                else:
                    consecutive_failures += 1
                    log_message(task_id, f"{process_id}: Send failed ({consecutive_failures}/3)")
                    
                    if consecutive_failures >= 3:
                        log_message(task_id, f"{process_id}: Too many failures, forcing restart...")
                        driver = None
                        consecutive_failures = 0
                    time.sleep(15)
                
                # Memory cleanup every 50 messages
                if task.messages_sent % 50 == 0 and task.messages_sent > 0:
                    try:
                        driver.execute_script("""
                            if(window.gc) window.gc();
                            localStorage.clear();
                            sessionStorage.clear();
                        """)
                        gc.collect()
                        log_message(task_id, f"{process_id}: ðŸ§¹ Memory cleaned")
                    except:
                        pass
                
            except Exception as e:
                log_message(task_id, f"{process_id}: âš ï¸ Error: {str(e)[:100]}")
                driver = None
                hard_kill_chromium(task_id)
                time.sleep(20)
        
        # Cleanup
        if driver:
            try:
                driver.quit()
            except:
                pass
        hard_kill_chromium(task_id)
        task.running = False
        if task_id in self.task_threads:
            del self.task_threads[task_id]
    
    def start_auto_resume(self):
        def auto_resume():
            while True:
                try:
                    for task_id, task in self.tasks.items():
                        if task.status == "running" and not task.running:
                            log_message(task_id, f"ðŸ”„ Auto-resuming task...")
                            self.start_task(task_id)
                except Exception as e:
                    print(f"Auto resume error: {e}")
                time.sleep(60)
        
        thread = threading.Thread(target=auto_resume, daemon=True)
        thread.start()

task_manager = TaskManager()

# ==================== TELEGRAM BOT HANDLERS ====================
def verify_user(telegram_id: str, secret_key: str = None) -> bool:
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    if secret_key:
        if secret_key == SECRET_KEY:
            cursor.execute('INSERT OR REPLACE INTO users (telegram_id, secret_key_verified) VALUES (?, ?)', (telegram_id, 1))
            conn.commit()
            conn.close()
            return True
        return False
    
    cursor.execute('SELECT secret_key_verified FROM users WHERE telegram_id = ?', (telegram_id,))
    result = cursor.fetchone()
    conn.close()
    return result and result[0] == 1

async def start_command(update: Update, context: CallbackContext):
    user_id = str(update.effective_user.id)
    if verify_user(user_id):
        await show_menu(update, context)
    else:
        await update.message.reply_text(
            f"Welcome to Raj Mishra end to end world\n\n"
            f"Please contact my owner: {OWNER_FB_LINK}\n\n"
            f"Send the secret key to continue:"
        )

async def handle_secret_key(update: Update, context: CallbackContext):
    user_id = str(update.effective_user.id)
    secret = update.message.text.strip()
    
    if verify_user(user_id, secret):
        await update.message.reply_text(
            "âœ… Welcome!\n\n"
            "Please choose option:\n\n"
            "A. Send cookies (one per line)\n"
            "B. Send chat thread ID\n"
            "C. Send messages file (.txt)\n"
            "D. Send name prefix\n"
            "E. Send time delay\n"
            "F. Send code to start task\n"
            "G. Manage tasks\n\n"
            "Send the option letter:"
        )
        context.user_data['verified'] = True
        context.user_data['setup_step'] = 'awaiting_option'
    else:
        await update.message.reply_text(f"âŒ Code galat hai! Contact owner: {OWNER_FB_LINK}")

async def handle_option(update: Update, context: CallbackContext):
    option = update.message.text.strip().upper()
    
    if option == 'A':
        context.user_data['setup_step'] = 'awaiting_cookies'
        await update.message.reply_text("Send your Facebook cookies (one per line):")
    elif option == 'B':
        context.user_data['setup_step'] = 'awaiting_chat_id'
        await update.message.reply_text("Send chat thread ID:")
    elif option == 'C':
        context.user_data['setup_step'] = 'awaiting_messages'
        await update.message.reply_text("Send .txt file with one message per line:")
    elif option == 'D':
        context.user_data['setup_step'] = 'awaiting_name_prefix'
        await update.message.reply_text("Send the name prefix:")
    elif option == 'E':
        context.user_data['setup_step'] = 'awaiting_delay'
        await update.message.reply_text("Send delay in seconds:")
    elif option == 'F':
        context.user_data['setup_step'] = 'awaiting_code'
        await update.message.reply_text("Send the code to start:")
    elif option == 'G':
        context.user_data['setup_step'] = 'awaiting_task_action'
        await update.message.reply_text(
            "Commands:\n"
            "/stop TASK_ID - Stop\n"
            "/resume TASK_ID - Resume\n"
            "/status TASK_ID - Status\n"
            "/delete TASK_ID - Delete\n"
            "/uptime TASK_ID - Uptime\n"
            "/logs TASK_ID - Logs\n"
            "/tasks - List all"
        )
    else:
        await update.message.reply_text("Invalid! Choose A-G")

async def handle_cookies(update: Update, context: CallbackContext):
    text = update.message.text.strip()
    cookies = [c.strip() for c in text.split('\n') if c.strip()]
    
    if 'config' not in context.user_data:
        context.user_data['config'] = {}
    context.user_data['config']['cookies'] = cookies
    
    await update.message.reply_text(f"âœ… {len(cookies)} cookie(s) saved!")
    context.user_data['setup_step'] = 'awaiting_option'
    await show_menu(update, context)

async def handle_chat_id(update: Update, context: CallbackContext):
    context.user_data['config']['chat_id'] = update.message.text.strip()
    await update.message.reply_text(f"âœ… Chat ID saved!")
    context.user_data['setup_step'] = 'awaiting_option'
    await show_menu(update, context)

async def handle_messages(update: Update, context: CallbackContext):
    if update.message.document:
        file = await update.message.document.get_file()
        file_content = await file.download_as_bytearray()
        messages = file_content.decode('utf-8').strip().split('\n')
        messages = [m.strip() for m in messages if m.strip()]
        
        context.user_data['config']['messages'] = messages
        await update.message.reply_text(f"âœ… {len(messages)} message(s) loaded!")
        context.user_data['setup_step'] = 'awaiting_option'
        await show_menu(update, context)
    else:
        await update.message.reply_text("Send as .txt file!")

async def handle_name_prefix(update: Update, context: CallbackContext):
    context.user_data['config']['name_prefix'] = update.message.text.strip()
    await update.message.reply_text("âœ… Name prefix saved!")
    context.user_data['setup_step'] = 'awaiting_option'
    await show_menu(update, context)

async def handle_delay(update: Update, context: CallbackContext):
    try:
        delay = int(update.message.text.strip())
        context.user_data['config']['delay'] = delay
        await update.message.reply_text(f"âœ… Delay: {delay} seconds")
        context.user_data['setup_step'] = 'awaiting_option'
        await show_menu(update, context)
    except:
        await update.message.reply_text("Send a valid number!")

async def handle_code(update: Update, context: CallbackContext):
    user_id = str(update.effective_user.id)
    code = update.message.text.strip()
    
    if code == CODE:
        config = context.user_data.get('config', {})
        
        required = ['cookies', 'chat_id', 'messages', 'name_prefix', 'delay']
        if not all(k in config for k in required):
            await update.message.reply_text("Complete all steps (A-E) first!")
            return
        
        task_id = f"rajmishra_{random.randint(10000, 99999)}"
        
        task = Task(
            task_id=task_id,
            telegram_id=user_id,
            cookies=config['cookies'],
            chat_id=config['chat_id'],
            name_prefix=config['name_prefix'],
            messages=config['messages'],
            delay=config['delay'],
            status="stopped",
            messages_sent=0,
            rotation_index=0,
            current_cookie_index=0,
            start_time=None,
            last_active=None,
            last_browser_restart=None
        )
        
        task_manager.tasks[task_id] = task
        task_manager.save_task(task)
        task_manager.start_task(task_id)
        
        await update.message.reply_text(
            f"âœ… Task started!\n\n"
            f"ðŸ“Œ ID: {task_id}\n"
            f"ðŸª Cookies: {len(config['cookies'])}\n"
            f"ðŸ’¾ Memory Limit: {MEMORY_LIMIT_MB}MB\n"
            f"â° Time Backup: {BROWSER_RESTART_HOURS} hours\n"
            f"ðŸ“Š Status: Running\n\n"
            f"ðŸ“ /logs {task_id} - Live console\n"
            f"ðŸ“ˆ /status {task_id} - Progress"
        )
        
        context.user_data['config'] = {}
        context.user_data['setup_step'] = 'awaiting_option'
        await show_menu(update, context)
    else:
        await update.message.reply_text(f"âŒ Wrong code! Contact owner.")

async def show_menu(update: Update, context: CallbackContext):
    menu = (
        "ðŸ“‹ Main Menu:\n\n"
        "A. Send cookies\n"
        "B. Send chat ID\n"
        "C. Send messages file\n"
        "D. Send name prefix\n"
        "E. Send delay\n"
        "F. Send code to start\n"
        "G. Manage tasks\n\n"
        "Send option letter:"
    )
    await update.message.reply_text(menu)

async def stop_task_command(update: Update, context: CallbackContext):
    if not context.args:
        await update.message.reply_text("Usage: /stop TASK_ID")
        return
    task_id = context.args[0]
    user_id = str(update.effective_user.id)
    if task_id not in task_manager.tasks:
        await update.message.reply_text("Task not found!")
        return
    if task_manager.tasks[task_id].telegram_id != user_id:
        await update.message.reply_text("Not your task!")
        return
    if task_manager.stop_task(task_id):
        await update.message.reply_text(f"âœ… Task {task_id} stopped!")

async def resume_task_command(update: Update, context: CallbackContext):
    if not context.args:
        await update.message.reply_text("Usage: /resume TASK_ID")
        return
    task_id = context.args[0]
    user_id = str(update.effective_user.id)
    if task_id not in task_manager.tasks:
        await update.message.reply_text("Task not found!")
        return
    if task_manager.tasks[task_id].telegram_id != user_id:
        await update.message.reply_text("Not your task!")
        return
    if task_manager.start_task(task_id):
        await update.message.reply_text(f"âœ… Task {task_id} resumed!")

async def status_task_command(update: Update, context: CallbackContext):
    if not context.args:
        await update.message.reply_text("Usage: /status TASK_ID")
        return
    task_id = context.args[0]
    user_id = str(update.effective_user.id)
    if task_id not in task_manager.tasks:
        await update.message.reply_text("Task not found!")
        return
    task = task_manager.tasks[task_id]
    if task.telegram_id != user_id:
        await update.message.reply_text("Not your task!")
        return
    
    # Get current memory
    current_memory = get_chrome_memory_mb()
    
    next_restart = ""
    if task.last_browser_restart:
        time_since = (datetime.now() - task.last_browser_restart).total_seconds() / 3600
        remaining = BROWSER_RESTART_HOURS - time_since
        if remaining > 0:
            next_restart = f"\nâ° Next time restart: {remaining:.1f} hours"
    
    memory_status = f"\nðŸ’¾ Current Memory: {current_memory:.0f}MB / {MEMORY_LIMIT_MB}MB"
    if current_memory > MEMORY_LIMIT_MB * 0.8:
        memory_status += " âš ï¸ (Will restart soon)"
    
    status_text = (
        f"ðŸ“Š Task: {task_id}\n\n"
        f"Status: {task.status}\n"
        f"Messages Sent: {task.messages_sent}\n"
        f"Rotation: {task.rotation_index}\n"
        f"Cookies: {len(task.cookies)}\n"
        f"Delay: {task.delay}s\n"
        f"Uptime: {task.get_uptime()}{next_restart}{memory_status}"
    )
    await update.message.reply_text(status_text)

async def delete_task_command(update: Update, context: CallbackContext):
    if not context.args:
        await update.message.reply_text("Usage: /delete TASK_ID")
        return
    task_id = context.args[0]
    user_id = str(update.effective_user.id)
    if task_id not in task_manager.tasks:
        await update.message.reply_text("Task not found!")
        return
    if task_manager.tasks[task_id].telegram_id != user_id:
        await update.message.reply_text("Not your task!")
        return
    if task_manager.delete_task(task_id):
        await update.message.reply_text(f"âœ… Task {task_id} deleted!")

async def uptime_task_command(update: Update, context: CallbackContext):
    if not context.args:
        await update.message.reply_text("Usage: /uptime TASK_ID")
        return
    task_id = context.args[0]
    user_id = str(update.effective_user.id)
    if task_id not in task_manager.tasks:
        await update.message.reply_text("Task not found!")
        return
    task = task_manager.tasks[task_id]
    if task.telegram_id != user_id:
        await update.message.reply_text("Not your task!")
        return
    await update.message.reply_text(f"â±ï¸ Uptime: {task.get_uptime()}")

async def logs_command(update: Update, context: CallbackContext):
    if not context.args:
        await update.message.reply_text("Usage: /logs TASK_ID")
        return
    task_id = context.args[0]
    user_id = str(update.effective_user.id)
    if task_id not in task_manager.tasks:
        await update.message.reply_text("Task not found!")
        return
    task = task_manager.tasks[task_id]
    if task.telegram_id != user_id:
        await update.message.reply_text("Not your task!")
        return
    
    logs = task_logs.get(task_id, [])
    if not logs:
        await update.message.reply_text("No logs yet.")
        return
    
    logs_text = "ðŸ“Š LIVE CONSOLE (Last 30):\n\n"
    for log in list(logs)[-30:]:
        log_clean = log[:70] if len(log) > 70 else log
        logs_text += f"â”‚ {log_clean}\n"
    
    logs_text += f"\nðŸ“ˆ Messages: {task.messages_sent} | Memory: {get_chrome_memory_mb():.0f}MB"
    
    if len(logs_text) > 4000:
        await update.message.reply_text(logs_text[:3500])
        await update.message.reply_text(logs_text[3500:])
    else:
        await update.message.reply_text(logs_text)

async def list_tasks_command(update: Update, context: CallbackContext):
    user_id = str(update.effective_user.id)
    user_tasks = [t for t in task_manager.tasks.values() if t.telegram_id == user_id]
    
    if not user_tasks:
        await update.message.reply_text("No tasks!")
        return
    
    tasks_list = "ðŸ“‹ Your Tasks:\n\n"
    for task in user_tasks:
        tasks_list += f"ðŸ†” {task.task_id}\n   Status: {task.status}\n   Sent: {task.messages_sent}\n   Uptime: {task.get_uptime()}\n---\n"
    
    await update.message.reply_text(tasks_list)

def health_check():
    import socket
    class HealthServer:
        def __init__(self, port=4000):
            self.port = port
        def start(self):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(('0.0.0.0', self.port))
            sock.listen(5)
            while True:
                try:
                    client, _ = sock.accept()
                    client.send(b"HTTP/1.1 200 OK\r\n\r\nOK")
                    client.close()
                except:
                    pass
    threading.Thread(target=HealthServer(PORT).start, daemon=True).start()

async def handle_message(update: Update, context: CallbackContext):
    user_id = str(update.effective_user.id)
    text = update.message.text.strip()
    
    if not verify_user(user_id) and text != SECRET_KEY:
        await start_command(update, context)
        return
    
    if text == SECRET_KEY:
        await handle_secret_key(update, context)
        return
    
    step = context.user_data.get('setup_step', 'awaiting_option')
    
    if step == 'awaiting_option':
        await handle_option(update, context)
    elif step == 'awaiting_cookies':
        await handle_cookies(update, context)
    elif step == 'awaiting_chat_id':
        await handle_chat_id(update, context)
    elif step == 'awaiting_name_prefix':
        await handle_name_prefix(update, context)
    elif step == 'awaiting_delay':
        await handle_delay(update, context)
    elif step == 'awaiting_code':
        await handle_code(update, context)
    else:
        await show_menu(update, context)

# ==================== MAIN ====================
def main():
    health_check()
    
    application = Application.builder().token(BOT_TOKEN).build()
    
    application.add_handler(CommandHandler("start", start_command))
    application.add_handler(CommandHandler("stop", stop_task_command))
    application.add_handler(CommandHandler("resume", resume_task_command))
    application.add_handler(CommandHandler("status", status_task_command))
    application.add_handler(CommandHandler("delete", delete_task_command))
    application.add_handler(CommandHandler("uptime", uptime_task_command))
    application.add_handler(CommandHandler("logs", logs_command))
    application.add_handler(CommandHandler("tasks", list_tasks_command))
    
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    application.add_handler(MessageHandler(filters.Document.ALL, handle_messages))
    
    print("=" * 60)
    print("ðŸš€ R4J M1SHR4 MEMORY-BASED BOT Started!")
    print(f"ðŸ’¾ Memory Limit: {MEMORY_LIMIT_MB}MB (restart if exceeds)")
    print(f"â° Time Backup: Every {BROWSER_RESTART_HOURS} hours")
    print(f"ðŸ”ª Hard kill enabled - no zombie processes")
    print(f"ðŸ“Š Message trigger: REMOVED (only memory + time)")
    print("=" * 60)
    print("âœ… Bot is LIVE! Will restart when memory is high")
    print("=" * 60)
    
    application.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
