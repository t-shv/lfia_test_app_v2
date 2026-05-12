import qrcode

# 1) List out the test-strip IDs you want to fake
ids = [
    "TS-0001",
    "TS-0002",
    "TS-0003",
    # …add as many as you like
]

# 2) Generate and save one PNG per ID
for tid in ids:
    qr = qrcode.QRCode(
        version=1,                                # 21×21 modules
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,                              # ~0.4 mm/module @300 dpi
        border=4
    )
    qr.add_data(tid)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    img.save(f"qr_{tid}.png")