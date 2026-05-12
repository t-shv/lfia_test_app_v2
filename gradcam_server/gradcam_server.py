# gradcam_server.py

import os
import io
import numpy as np
from fastapi import FastAPI, File, UploadFile
from fastapi.responses import StreamingResponse
import uvicorn
from PIL import Image
import tensorflow as tf
from tf_explain.core.grad_cam import GradCAM
import cv2


app = FastAPI()

# 1) Load your Keras model once at startup
MODEL_PATH = "best_model_05.keras"  # make sure this file lives in gradcam_server/
model = tf.keras.models.load_model(MODEL_PATH)
model.trainable = False

# 2) Find the name of the last Conv2D layer in your model
LAST_CONV_LAYER = None
for layer in model.layers[::-1]:
    if isinstance(layer, tf.keras.layers.Conv2D):
        LAST_CONV_LAYER = layer.name
        break

if LAST_CONV_LAYER is None:
    raise RuntimeError("No Conv2D layer found in the model")

# 3) Function to turn raw bytes into a normalized (1,256,256,1) array
def preprocess_image(image_bytes: bytes):
    img = Image.open(io.BytesIO(image_bytes)).convert("L")  # grayscale
    img = img.resize((256, 256))
    arr = np.array(img, dtype=np.float32) / 255.0  # shape: (256,256)
    arr = np.expand_dims(arr, axis=-1)  # shape: (256,256,1)
    arr = np.expand_dims(arr, axis=0)   # shape: (1,256,256,1)
    return arr

# 4) Generate Grad-CAM overlay as a PNG in-memory
def make_gradcam_overlay(image_bytes: bytes):
    # a) Preprocess to shape (1,256,256,1)
    gray_input = preprocess_image(image_bytes)

    # b) tf-explain expects a 3-channel image, so tile it into RGB
    rgb_input = np.tile(gray_input, (1, 1, 1, 3))  # shape: (1,256,256,3)

    # c) Prepare data for tf-explain (image, label). Label can be None.
    data = ([rgb_input[0], None], None)

    # d) Run GradCAM
    explainer = GradCAM()
    # If you want a specific class (e.g. positive=1), pass class_index=1. 
    # None means “use top-predicted class.”
    grid = explainer.explain(
        data,
        model,
        class_index=None,
        layer_name=LAST_CONV_LAYER
    )
    # `grid` is a NumPy array shape (256,256,3) with a heatmap overlay.

    # e) Convert to PNG bytes
    overlay_img = Image.fromarray(grid.astype(np.uint8))
    buf = io.BytesIO()
    overlay_img.save(buf, format="PNG")
    buf.seek(0)
    return buf

@app.post("/debug/gradcam")
async def gradcam_endpoint(file: UploadFile = File(...)):
    """
    Expects a multipart/form-data upload under key 'file'.
    Returns a PNG of the Grad-CAM heatmap overlay.
    """
    image_bytes = await file.read()
    overlay_buf = make_gradcam_overlay(image_bytes)
    return StreamingResponse(overlay_buf, media_type="image/png")

if __name__ == "__main__":
    # Launch Uvicorn on port 8000
    uvicorn.run("gradcam_server:app", host="0.0.0.0", port=8000, reload=True)
