import sys
import subprocess
import threading
import os
from PySide6.QtWidgets import QApplication, QWidget, QVBoxLayout, QTextEdit, QPushButton, QLineEdit, QLabel, QHBoxLayout
from PySide6.QtGui import QFont, QIcon
from PySide6.QtCore import Qt, Signal

class PythonAppGUI(QWidget):
    add_log_signal = Signal(str, str)  # text, type: stdout/stderr/user

    def __init__(self, python_app_path):
        super().__init__()
        self.python_app_path = python_app_path
        self.proc = None
        self.add_log_signal.connect(self.add_log)

        self.setWindowTitle("🚀 tiny agent")
        self.setWindowIcon(QIcon.fromTheme("applications-python"))
        self.resize(900, 650)

        layout = QVBoxLayout()
        layout.setContentsMargins(32, 32, 32, 32)
        layout.setSpacing(20)

        # Auto Detect 按鈕
        top_bar = QHBoxLayout()
        self.auto_detect_enabled = False
        self.btn_auto_detect = QPushButton("✔ Auto Detect")
        self.btn_auto_detect.setCheckable(True)
        self.btn_auto_detect.setStyleSheet("padding: 8px 18px; font-size: 15px;")
        self.btn_auto_detect.clicked.connect(self.toggle_auto_detect)
        top_bar.addWidget(self.btn_auto_detect)
        top_bar.addStretch(1)
        layout.addLayout(top_bar)

        # 標題
        title = QLabel("🚀 tiny agent")
        title.setFont(QFont("Segoe UI", 26, QFont.Bold))
        title.setAlignment(Qt.AlignCenter)
        layout.addWidget(title)

        # Log 輸出區
        self.log_output = QTextEdit()
        self.log_output.setReadOnly(True)
        self.log_output.setFont(QFont("Consolas", 12))
        layout.addWidget(self.log_output, stretch=2)

        # 輸入區
        input_widget = QWidget()
        input_layout = QHBoxLayout()
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

        # 啟動子程式
        threading.Thread(target=self.start_python_app, daemon=True).start()

    def toggle_auto_detect(self):
        self.auto_detect_enabled = not self.auto_detect_enabled
        if self.auto_detect_enabled:
            self.btn_auto_detect.setText("✔ Auto Detect")
            self.btn_auto_detect.setStyleSheet("padding: 8px 18px; font-size: 15px; background: #1dd1a1; color: white;")
        else:
            self.btn_auto_detect.setText("✖ Auto Detect")
            self.btn_auto_detect.setStyleSheet("padding: 8px 18px; font-size: 15px;")

    def start_python_app(self):
        if self.proc and self.proc.poll() is None:
            self.add_log_signal.emit("⚠️ Python App already running.", "stderr")
            return

        self.proc = subprocess.Popen(
            [sys.executable, self.python_app_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
            text=True,
            bufsize=1
        )

        threading.Thread(target=self.read_stream, args=(self.proc.stdout, "stdout"), daemon=True).start()
        threading.Thread(target=self.read_stream, args=(self.proc.stderr, "stderr"), daemon=True).start()

    def stop_python_app(self):
        print("exit")
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.add_log_signal.emit("⏹ Python App stopped.", "stderr")
            self.proc = None
        self.add_log_signal.emit("🛑 GUI stopped.", "stderr")
        QApplication.instance().quit()

    def send_input(self):
        if self.proc and self.proc.poll() is None:
            text = self.input_box.text()
            if text.strip():
                self.add_log_signal.emit(f"> {text}", "user")
                try:
                    self.proc.stdin.write(text + "\n")
                    self.proc.stdin.flush()
                except Exception as e:
                    self.add_log_signal.emit(f"❌ Failed to send input: {e}", "stderr")
            self.input_box.clear()

    def read_stream(self, stream, stream_type):
        for line in iter(stream.readline, ''):
            if line.strip():
                self.add_log_signal.emit(line.strip(), stream_type)
        stream.close()

    def add_log(self, text, log_type="stdout"):
        if log_type == "stderr":
            color = "red"
        elif log_type == "user":
            color = "green"
        else:
            color = "black"
        self.log_output.append(f'<span style="color:{color}">{text}</span>')
        self.log_output.verticalScrollBar().setValue(self.log_output.verticalScrollBar().maximum())


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
