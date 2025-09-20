import sys
import subprocess
import threading
import time
import os
from PySide6.QtWidgets import QApplication, QWidget, QVBoxLayout, QTextEdit, QPushButton, QLineEdit, QLabel
from PySide6.QtGui import QTextCursor, QColor, QTextCharFormat
from PySide6.QtWidgets import QHBoxLayout, QSizePolicy
from PySide6.QtGui import QFont, QIcon
from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import QSplitter
from PySide6.QtWidgets import QScrollArea
from PySide6.QtWidgets import QCheckBox


# ------------------ GUI ------------------
class ChatBubble(QLabel):
    def __init__(self, text, is_user=True):
        super().__init__()
        self.setText(text)
        self.setWordWrap(True)
        self.setMargin(8)
        self.setFont(QFont("Segoe UI", 15))
        self.setStyleSheet(f"""
            QLabel {{
                background: {'#10ac84' if is_user else '#222f3e'};
                color: {'white' if is_user else '#f5f6fa'};
                border-radius: 8px;
                padding: 8px 14px;
                max-width: 600px;
            }}
        """)
        self.setSizePolicy(QSizePolicy.Maximum, QSizePolicy.Maximum)
        self.setAlignment(Qt.AlignLeft if not is_user else Qt.AlignRight)

    def showEvent(self, event):
        super().showEvent(event)
        # 聊天泡泡顯示時自動捲到最底部
        parent = self.parent()
        while parent:
            if hasattr(parent, "scroll") and hasattr(parent.scroll, "verticalScrollBar"):
                QApplication.processEvents()
                parent.scroll.verticalScrollBar().setValue(parent.scroll.verticalScrollBar().maximum())
                break
            parent = parent.parent()

class PythonAppGUI(QWidget):
    add_bubble_signal = Signal(str, bool)

    def __init__(self, python_app_path):
        super().__init__()
        self.python_app_path = python_app_path
        self.proc = None
        self.add_bubble_signal.connect(self.add_bubble)

        self.setWindowTitle("🚀 tiny agent")
        self.setWindowIcon(QIcon.fromTheme("applications-python"))
        self.resize(900, 650)
        self.setStyleSheet("""
            QWidget {
                background-color: qlineargradient(x1:0, y1:0, x2:1, y2:1,
                    stop:0 #f5f6fa, stop:1 #dff9fb);
            }
            QLineEdit {
                background: #fff;
                border: 2px solid #10ac84;
                border-radius: 10px;
                padding: 10px;
                font-size: 16px;
                margin-right: 8px;
            }
            QPushButton {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:1,
                    stop:0 #10ac84, stop:1 #1dd1a1);
                color: white;
                border-radius: 10px;
                font-size: 17px;
                padding: 12px 28px;
                font-weight: bold;
                border: none;
            }
            QPushButton:hover {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:1,
                    stop:0 #1dd1a1, stop:1 #10ac84);
            }
            QLabel#TitleLabel {
                color: #222f3e;
                margin-bottom: 8px;
                letter-spacing: 1px;
            }
        """)

        layout = QVBoxLayout()
        layout.setContentsMargins(32, 32, 32, 32)
        layout.setSpacing(20)

        # Top bar (add auto detect button)
        top_bar = QHBoxLayout()
        self.auto_detect_enabled = False
        self.btn_auto_detect = QPushButton()
        self.btn_auto_detect.setText("✔ Auto Detect")
        self.btn_auto_detect.setCheckable(True)
        self.btn_auto_detect.setStyleSheet("padding: 8px 18px; font-size: 15px;")
        self.btn_auto_detect.clicked.connect(self.toggle_auto_detect)
        top_bar.addWidget(self.btn_auto_detect)
        top_bar.addStretch(1)
        layout.addLayout(top_bar)

        title = QLabel("🚀 tiny agent")
        title.setObjectName("TitleLabel")
        title.setFont(QFont("Segoe UI", 26, QFont.Bold))
        title.setAlignment(Qt.AlignCenter)
        layout.addWidget(title)

        # 聊天區域
        self.chat_area = QWidget()
        self.chat_layout = QVBoxLayout()
        self.chat_layout.setSpacing(16)
        self.chat_layout.addStretch(1)
        self.chat_area.setLayout(self.chat_layout)
        self.chat_area.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

        # 滾動區域
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setWidget(self.chat_area)
        self.scroll.setStyleSheet("QScrollArea {background: transparent; border: none;}")

        layout.addWidget(self.scroll, stretch=2)

        # 輸入區
        input_widget = QWidget()
        input_layout = QHBoxLayout()
        input_layout.setSpacing(12)
        self.input_box = QLineEdit()
        self.input_box.setPlaceholderText("Type your message and press Enter...")
        self.input_box.returnPressed.connect(self.send_input)
        input_layout.addWidget(self.input_box, stretch=2)

        self.btn_stop = QPushButton("⏹ Quit")
        self.btn_stop.clicked.connect(self.stop_python_app)
        input_layout.addWidget(self.btn_stop, stretch=1)

        input_widget.setLayout(input_layout)
        layout.addWidget(input_widget)

        self.setLayout(layout)

        threading.Thread(target=self.start_python_app, daemon=True).start()

    def toggle_auto_detect(self):
        self.auto_detect_enabled = not self.auto_detect_enabled
        if self.auto_detect_enabled:
            self.btn_auto_detect.setText("✔ Auto Detect")
            self.btn_auto_detect.setStyleSheet("padding: 8px 18px; font-size: 15px; background: #1dd1a1; color: white;")
            # auto detect emotion
        else:
            self.btn_auto_detect.setText("✖ Auto Detect")
            self.btn_auto_detect.setStyleSheet("padding: 8px 18px; font-size: 15px;")

    def start_python_app(self):
        if self.proc and self.proc.poll() is None:
            self.add_bubble("⚠️ Python App already running.", is_user=False)
            return

        self.proc = subprocess.Popen(
            [sys.executable, self.python_app_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
            text=True,
            bufsize=1
        )

        threading.Thread(target=self.read_stream, args=(self.proc.stdout, False), daemon=True).start()
        threading.Thread(target=self.read_stream, args=(self.proc.stderr, False), daemon=True).start()

    def stop_python_app(self):
        print("exit")
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.add_bubble("⏹ Python App stopped.", is_user=False)
            self.proc = None
        self.add_bubble("🛑 GUI stopped.", is_user=False)
        QApplication.instance().quit()

    def send_input(self):
        if self.proc and self.proc.poll() is None:
            text = self.input_box.text()
            if text.strip():
                self.add_bubble(text, is_user=True)
                try:
                    self.proc.stdin.write(text + "\n")
                    self.proc.stdin.flush()
                except Exception as e:
                    self.add_bubble(f"❌ Failed to send input: {e}", is_user=False)
            self.input_box.clear()
    def read_stream(self, stream, is_user):
        for line in iter(stream.readline, ''):
            if line.strip():
                self.add_bubble_signal.emit(line.strip(), False)
        stream.close()

    def add_bubble(self, text, is_user=True):
        bubble = ChatBubble(text, is_user)
        self.chat_layout.insertWidget(self.chat_layout.count()-1, bubble, alignment=Qt.AlignRight if is_user else Qt.AlignLeft)
        # 滾動到底部
        QApplication.processEvents()
        self.scroll.verticalScrollBar().setValue(self.scroll.verticalScrollBar().maximum())


# ------------------ 主程式 ------------------
if __name__ == "__main__":
    app = QApplication(sys.argv)

    if len(sys.argv) < 2:
        print("Usage: python gui_client.py <PythonAppPath>")
        sys.exit(1)

    PYTHON_APP_PATH = sys.argv[1]
    if not os.path.exists(PYTHON_APP_PATH):
        print(f"Error: Python app not found: {PYTHON_APP_PATH}")
        sys.exit(1)

    gui = PythonAppGUI(PYTHON_APP_PATH)
    gui.show()
    sys.exit(app.exec())
