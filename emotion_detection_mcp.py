from deepface import DeepFace
import cv2
import time
from fastmcp import FastMCP

# 初始化 FastMCP
mcp = FastMCP("emotion_detection")

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

@mcp.tool()
async def emotion_detect() -> str:
    """從攝影機擷取影像並進行情緒分析"""
    duration = 10 
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
        return (f"在 {duration} 秒內的主要情緒是：{dominant_emotion}，平均機率：{avg_emotions[dominant_emotion]:.2f}")
    else:
        return (f"在 {duration} 秒內未偵測到任何情緒")

if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="127.0.0.1", port=8000)
