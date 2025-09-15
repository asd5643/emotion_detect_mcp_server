from mcp.server.fastmcp import FastMCP
import cv2
from deepface import DeepFace

# Initialize FastMCP server
mcp = FastMCP("emotion_detection")

@mcp.tool()
async def emotion_detect() -> str:
    """Capture a photo and identify the emotion shown on the face"""
    cap = cv2.VideoCapture(0)
    ret, frame = cap.read()
    cap.release()

    if not ret:
        return "Failed to capture image"

    try:
        result = DeepFace.analyze(frame, actions=['emotion'], enforce_detection=False)
        if isinstance(result, list):
            result = result[0]  # 只取第一張臉

        return result['dominant_emotion']
    except Exception as e:
        return f"Error during analysis: {str(e)}"

if __name__ == "__main__":
    mcp.run(transport='stdio')
