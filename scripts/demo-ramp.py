# Allocates 2 GB in steps, holds it, and gives it back: the Python tile that
# swells and shrinks in the README clip. Run it beside `memtree --record`.
import time
chunks = []
time.sleep(2.5)
for _ in range(16):              # 16 x 128 MB = 2 GB over 8 s
    chunks.append(b"\x01" * (128 << 20))
    time.sleep(0.5)
time.sleep(2)
while chunks:                    # and give it all back
    del chunks[-2:]
    time.sleep(0.35)
time.sleep(5)
