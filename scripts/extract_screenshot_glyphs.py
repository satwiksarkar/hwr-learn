import os
import json
from PIL import Image
import numpy as np
from scipy.ndimage import label

img = Image.open('reference/screenshot.png').convert('RGB')
arr = np.array(img)
yellow_mask = (arr[:, :, 0] > 180) & (arr[:, :, 1] > 180) & (arr[:, :, 2] < 120)

canvas_mask = np.zeros_like(yellow_mask)
canvas_mask[100:440, 50:900] = yellow_mask[100:440, 50:900]

labeled, num_features = label(canvas_mask)

comps = []
for i in range(1, num_features + 1):
    ys, xs = np.where(labeled == i)
    if len(ys) > 10:
        # Sample points to make stroke representation
        # Take a downsampled sequence of coordinates
        pts = [{"x": int(x), "y": int(y)} for x, y in zip(xs[::2], ys[::2])]
        comps.append({
            'id': i,
            'x1': int(np.min(xs)), 'x2': int(np.max(xs)),
            'y1': int(np.min(ys)), 'y2': int(np.max(ys)),
            'w': int(np.max(xs) - np.min(xs) + 1),
            'h': int(np.max(ys) - np.min(ys) + 1),
            'points': pts
        })

comps.sort(key=lambda c: c['x1'])

out_path = os.path.join(os.path.dirname(__file__), '..', 'tests', 'screenshot_glyphs.json')
with open(out_path, 'w') as f:
    json.dump(comps, f, indent=2)

print(f"Extracted {len(comps)} glyphs to {out_path}")
