import os
import random
from glob import glob
from PIL import Image, ImageEnhance, ImageFilter

# folders
classes = ['Positive', 'Negative']
input_dir  = '63 New Dataset'        # contains Positive/ and Negative/
output_dir = '63_large_augmented_dataset'      # will be created

# how many augments per image
AUG_PER_IMAGE = 5

# make sure output dirs exist
for cls in classes:
    os.makedirs(os.path.join(output_dir, cls), exist_ok=True)

def random_brightness(img):
    enhancer = ImageEnhance.Brightness(img)
    factor = random.uniform(0.7, 1.3)  # darker → brighter
    return enhancer.enhance(factor)

def random_contrast(img):
    enhancer = ImageEnhance.Contrast(img)
    factor = random.uniform(0.7, 1.3)
    return enhancer.enhance(factor)

def random_color(img):
    enhancer = ImageEnhance.Color(img)
    factor = random.uniform(0.8, 1.2)  # saturation
    return enhancer.enhance(factor)

def random_sharpness(img):
    enhancer = ImageEnhance.Sharpness(img)
    factor = random.uniform(0.8, 1.5)
    return enhancer.enhance(factor)

def random_noise(img):
    arr = img.convert('RGB')
    px = arr.load()
    w, h = arr.size
    for _ in range(int(w*h*0.005)):  # noise on 0.5% of pixels
        x = random.randrange(w)
        y = random.randrange(h)
        px[x, y] = tuple(min(255, max(0, c + random.randint(-30, 30))) for c in px[x,y])
    return arr

def random_blur(img):
    if random.random() < 0.3:
        return img.filter(ImageFilter.GaussianBlur(radius=random.uniform(0.5, 1.5)))
    return img

def random_geom(img):
    # small rotate, translate, scale
    angle = random.uniform(-10, 10)
    img = img.rotate(angle, resample=Image.BILINEAR, expand=False)
    # you could add translate or scale via affine if you like
    return img

def augment_image(img):
    funcs = [
        random_brightness,
        random_contrast,
        random_color,
        random_sharpness,
        random_noise,
        random_blur,
        random_geom
    ]
    # pick a random subset of 3–5 transforms and apply in random order
    ops = random.sample(funcs, k=random.randint(3, 5))
    out = img
    for fn in ops:
        out = fn(out)
    return out

# process all images
for cls in classes:
    files = glob(os.path.join(input_dir, cls, '*.jpg'))
    for path in files:
        fname = os.path.basename(path)
        # copy original
        img = Image.open(path)
        img.save(os.path.join(output_dir, cls, fname))

        # create augmented copies
        for i in range(AUG_PER_IMAGE):
            aug = augment_image(img)
            name, ext = os.path.splitext(fname)
            new_name = f"{name}_aug{i}{ext}"
            aug.save(os.path.join(output_dir, cls, new_name))

print("Done!")
