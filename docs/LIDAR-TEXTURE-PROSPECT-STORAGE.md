# LiDAR: photo texture, path to the prospect, storage budget

Numbers come from Mark's run on build 3795796 (iPhone 16 Pro, 10 Nov, attic + stairs): 363 s, 311 keyframes + 825 depth-only frames, 788k triangles, 251 MB, about 53 m² of floor.

## LIDAR-95: sharper photo texture

Why the current Texture mode is soft:
- It gives each mesh vertex one colour. The vertices are about 3 cm apart, so detail smaller than that is lost.
- The 640 px photos are not what limits it. At 2 m, a 640 px photo still has about 5 mm per pixel.
- Raising the photo size in that mode would not make it visibly sharper.

What is built now (on the phone, new "Photo" mode in the 3D viewer):
- Each triangle takes its image straight from the best full keyframe: the closest, most front-facing and least off-centre photo where the depth agrees, so a wall behind furniture is not painted with the furniture.
- The triangles get texture coordinates into that photo, so detail inside a triangle comes from the photo itself, not from 3 vertex colours.
- At most 24 photos are used, at 1440 px, to keep memory near 150 MB. Triangles not in those photos stay grey, and the viewer says what share of the mesh is covered.
- Cost: built on the phone when the mode is opened, with no server work. On 788k triangles, expect several seconds up to about a minute (not measured on a device yet).
- Not checked on a device yet: the seams between photos, exposure jumps between photos, and that the image is not flipped.

Next option if this is not good enough, on the server:
- Build one texture atlas from all keyframes with seam levelling, for example with mvs-texturing or Open3D, from the uploaded zip.
- Cost: about 3 to 5 days, plus a worker that can handle 250 MB zips and run for minutes per scan.
- It gives an evenly lit texture without seams, which the phone version cannot.

High-res stills during RoomPlan:
- ARKit can take a full-resolution still while running (`captureHighResolutionFrame`).
- It is not used yet. It must first be tried on a device to see whether it hurts tracking. Our keyframes are already 1920 × 1440, which is enough for the texture above.

## LIDAR-100: path from zip to prospect

What exists now:
- The prospect sees the web tour: plan, dollhouse from the RoomPlan boxes, and photos. The LiDAR mesh stays on the phone.

Built now (step 1):
- "Share 3D model" in the 3D viewer saves the current view as a USDZ file and opens the share sheet.
- On an iPhone or a Mac, the prospect can open it with Quick Look and turn it, or view it in AR.
- Not checked on a device yet: whether the photo texture and the colours survive in the USDZ export. A plain mesh does.

Next steps, with cost:
1. Upload the USDZ, or a GLB made from it, with the scan. Store it beside the dollhouse files and add a "LiDAR model" button to the web tour (three.js already loads GLB). About 2 days.
2. On the server, make a lighter version of the mesh (about 150k triangles) for the web, so it loads on a phone browser. About 1 to 2 days.
3. Optional: the server texture from LIDAR-95 replaces the phone texture. 3 to 5 days, as above.

## LIDAR-101: on-device storage budget

Measured from Mark's run:
- About 41.5 MB per minute, or about 4.7 MB per m² of floor.
- A 150 m² house is about 0.7 GB. A 30-minute scan is about 1.2 GB.

Built now:
- The recorder checks the free space every 5 s and saves the lowest value in capture.json as `lowest_free_disk_mb`.
- Below 2 GB free, a line under the ring shows about how many minutes and m² are left.
- Below 1 GB free, the recorder stops saving frames, so the phone does not run out of space. The room plan and the mesh are still saved. A warning is shown, and the gap reason is `low_storage`.
- Only captures linked to a saved scan are kept, up to 10, as before.

Open:
- The MB per minute and per m² come from one run. They will be updated after the next runs.
