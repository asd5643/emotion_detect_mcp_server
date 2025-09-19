import cv2
import numpy as np
from deepface import DeepFace
import time

detect_period = 20  # 每隔 20 秒偵測一次

def capture_image():
    """從攝影機擷取一張影像"""
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("無法開啟攝影機")
        return None
    ret, frame = cap.read()
    cap.release()
    if not ret:
        print("無法擷取影像")
        return None
    return frame

def analyze_emotion(image):
    """使用 DeepFace 進行情緒分析"""
    try:
        result = DeepFace.analyze(image, actions=['emotion'], enforce_detection=False)
        return result[0]['emotion']
    except Exception as e:
        print(f"情緒分析過程中發生錯誤：{str(e)}")
        return None

def main(duration=10):
    """主程式：連續偵測指定時間並計算情緒平均機率"""
    start_time = time.time()
    emotion_counts = {emotion: 0 for emotion in ["angry", "disgust", "fear", "happy", "sad", "surprise", "neutral"]}
    frame_count = 0

    while time.time() - start_time < duration:
        frame = capture_image()
        if frame is None:
            continue

        emotions = analyze_emotion(frame)
        if emotions:
            frame_count += 1
            for emotion, prob in emotions.items():
                emotion_counts[emotion] += prob

    if frame_count > 0:
        avg_emotions = {emotion: prob / frame_count for emotion, prob in emotion_counts.items()}
        dominant_emotion = max(avg_emotions, key=avg_emotions.get)
        print(f"在 {duration} 秒內的主要情緒是：{dominant_emotion}，平均機率：{avg_emotions[dominant_emotion]:.2f}")
        if (dominant_emotion != "neutral") and (avg_emotions[dominant_emotion] > 0.6):
            print("偵測到強烈情緒反應！")       # open tiny agent！
    else:
        print(f"在 {duration} 秒內未偵測到任何情緒")

if __name__ == "__main__":
    start_time_main = time.time()
    while True:
        if time.time() - start_time_main > detect_period:
            main(duration=10)  # 設定偵測時間為 10 秒
            start_time_main = time.time()
        time.sleep(1)  # 每 20 秒偵測一次
        print(time.time()-start_time_main)