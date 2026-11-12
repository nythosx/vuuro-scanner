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
- At most 40 photos are used, at 1152 × 864 px. The photos alone take about 160 MB; with the mesh copies and the visibility data, the peak on 788k triangles is estimated at about 300 MB (not measured on a device yet). Triangles not in those photos stay grey, and the viewer says what share of the mesh is covered and how long the build took.
- The photos are picked to cover the most triangles, one after another, instead of the photos that are best for the most triangles. On Mark's zip, 24 photos picked the old way covered 60% of the mesh; 40 photos picked by coverage cover 88% (any photo at all could cover 94%).
- Brightness is evened out between photos: where two photos see the same triangles, their brightness is compared, and each photo gets one gain (0.6 to 1.6) so they match. On Mark's zip, the median brightness jump where photos meet went from 1.25x to 1.05x, and the worst 10% from 1.73x to 1.27x.
- Orientation checked on Mark's zip: projecting the mesh into the photos matches the depth for 78% of points as built, and 32% if the image were flipped, so the image rows are the right way up. Whether SceneKit reads the texture coordinates the same way is still to be seen on a device.
- Cost: built on the phone when the mode is opened, with no server work. The visibility pass runs on all CPU cores. On a PC, the same work on Mark's 788k triangles took about 28 s in Python, so expect tens of seconds on the phone (not measured on a device yet).
- Not checked on a device yet: the seams between photos and the build time.

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
- The photo texture is handed to SceneKit as a UIImage, which the USDZ export can write as a texture file.
- Not checked on a device yet: whether the photo texture and the Texture mode colours survive in the USDZ export. A plain mesh does.

Next steps, with cost:
1. Upload the USDZ, or a GLB made from it, with the scan. Store it beside the dollhouse files and add a "LiDAR model" button to the web tour (three.js already loads GLB). About 2 days.
2. On the server, make a lighter version of the mesh (about 150k triangles) for the web, so it loads on a phone browser. About 1 to 2 days.
3. Optional: the server texture from LIDAR-95 replaces the phone texture. 3 to 5 days, as above.

## LIDAR-101: on-device storage budget

Measured from Mark's run:
- 10 Nov run: about 41.5 MB per minute, or about 4.7 MB per m² of floor.
- 12 Nov run (attic with stairs, 315 s, 376 keyframes and 1008 depth-only frames): 313.5 MB, 57 MB per minute, or about 6 MB per m² of the 51.6 m² floor seen.
- The app now plans with 57 MB per minute, the higher of the two. A 150 m² house is about 0.7 to 0.9 GB. A 30-minute scan is about 1.7 GB.

Built now:
- The recorder checks the free space every 5 s and saves the lowest value in capture.json as `lowest_free_disk_mb`.
- Below 2 GB free, a line under the ring shows about how many minutes and m² are left. The minutes use the MB per minute measured so far in the same run, and 57 MB per minute until at least 10 s are recorded.
- Below 1 GB free, the recorder stops saving frames, so the phone does not run out of space. The room plan and the mesh are still saved. A warning is shown, and the gap reason is `low_storage`.
- Only captures linked to a saved scan are kept, up to 10, as before.

Checked against a second run:
- Mark's 4 Nov run (71 s, keyframes only) used 42.7 MB per minute, close to the 41.5 from the 10 Nov run.
- Mark's 12 Nov run used 57 MB per minute, so the planning rate was raised from 41.5 to 57. The m² left now uses 6.1 MB per m², the 12 Nov figure and the higher of the two runs.
- The proof screen now shows the MB per minute and the lowest free storage of each run, so the numbers can be read from every new run without the zip.

Open:
- The MB per m² comes from one run only.
