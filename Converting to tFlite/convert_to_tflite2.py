import tensorflow as tf

# 1) load your Keras model
model = tf.keras.models.load_model('new_model.keras')

# 2) convert to TFLite
converter = tf.lite.TFLiteConverter.from_keras_model(model)
tflite_model = converter.convert()

# 3) write out the .tflite file
with open('new_model.tflite', 'wb') as f:
    f.write(tflite_model)

print("Conversion complete: new_model.tflite")
