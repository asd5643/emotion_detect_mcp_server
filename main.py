from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from deepface import DeepFace
import cv2
import json
import os
import sys
pic_tool = 0
app = FastAPI()

if not os.path.exists("C:\\Users\\04071\\Desktop\\hackerthon\\mcp\\config.json"):
    print("Error: config.json not found in the current directory.", file=sys.stderr)
    exit(1)

# 載入設定檔（可選，如果你需要工具清單從 config.json）
with open("C:\\Users\\04071\\Desktop\\hackerthon\\mcp\\config.json", "r", encoding="utf-8") as f:
    config = json.load(f)

# MCP manifest - 告訴 Claude 有哪些工具
@app.get("/manifest")
def manifest():
    return {
        "tools": config.get("tools", {
            "detect_emotion": {
                "description": "拍照並分析表情",
                "parameters": {}
            }
        })
    }

# MCP 主入口 - 接收工具請求
@app.post("/")
async def mcp_handler(request: Request):
    data = await request.json()
    tool = data.get("tool")

    if tool == "detect_emotion":
        return detect_emotion()

    return JSONResponse(status_code=400, content={"error": f"Unknown tool: {tool}"})

# 工具實作：拍照並分析情緒
def detect_emotion():
    cap = cv2.VideoCapture(0)
    ret, frame = cap.read()
    cap.release()

    if not ret:
        return JSONResponse(status_code=500, content={"error": "無法開啟相機或拍照失敗"})

    try:
        if pic_tool == 0:
            result = DeepFace.analyze(frame, actions=['emotion'], enforce_detection=False)
            emotion = result[0]['dominant_emotion']
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": f"DeepFace 分析失敗: {str(e)}"})

    return {"output": {"emotion": emotion}}

if __name__ == "__main__":
    print("Starting MCP server...", file=sys.stderr)
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8010)