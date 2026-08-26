Import("env")

from pathlib import Path

OTA_SLOT_SIZE = 0x1E0000


def verify_ota_image(source, target, env):
    image = Path(str(target[0]))
    size = image.stat().st_size
    if size > OTA_SLOT_SIZE:
        raise RuntimeError(
            f"firmware.bin is {size} bytes and exceeds the {OTA_SLOT_SIZE}-byte OTA slot"
        )
    print(
        f"InputPilot OTA slot check: {size}/{OTA_SLOT_SIZE} bytes "
        f"({OTA_SLOT_SIZE - size} bytes free)"
    )


env.AddPostAction("$BUILD_DIR/${PROGNAME}.bin", verify_ota_image)
