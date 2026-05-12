import tensorflow as tf

# 1) load your Keras model
model = tf.keras.models.load_model('best_model_63.keras')

# 2) convert to TFLite
converter = tf.lite.TFLiteConverter.from_keras_model(model)
tflite_model = converter.convert()

# 3) write out the .tflite file
with open('63_model.tflite', 'wb') as f:
    f.write(tflite_model)

print("Conversion complete: 63_model.tflite")
