# QA device smoke test (iPhone Pro)

A short run on a real LiDAR iPhone to check that one room captures, saves its LiDAR proof, exports the zip and opens again from History. It takes about 10 minutes.

## Before you start

- iPhone with LiDAR: iPhone 12 Pro or newer Pro / Pro Max.
- The Vuuro Scan build to test is installed, and the Scan Service URL it uses can be reached from the phone.
- Write down the build:
  - Open Settings and note the git sha shown at the top, plus the server URL.
  - Every report starts with the sha, the phone model and the iOS version.
- In Settings, leave "Photos for the tour after each room" off. That is the default.

## Steps

1. **Settings**
   - Check that the git sha at the top matches the build you were asked to test.
   - Take a screenshot.
2. **Start one room**
   - Start a new scan and scan one room. Walk slowly along the walls, and point the phone at the floor and once at the ceiling.
3. **Coverage map**
   - Check that the map next to the wall ring is visible while scanning. It shows floor seen and missing, walls, corners, your path and one hint at a time.
   - Tap "Hide map", then "Map", and check that it comes back.
   - Take a screenshot with a hint showing.
4. **Finish room, skip photos**
   - Tap Finish.
   - With the default setting, the app goes straight on and the "Photos for the tour" step does not open.
   - If that step opens anyway, tap Skip and note it in the report.
   - After the upload, the notes and photos screen opens straight away, with no "Room 1 captured" screen in between.
5. **Result and LiDAR proof**
   - Wait for the upload and the result screen.
   - Open the LiDAR capture button and check:
     - Device and iOS
     - Depth received: yes
     - Mesh received: yes
     - the "Room 1 LiDAR" line
     - the floor, walls and corners coverage rows
     - "Recording gaps over 2 s"
     - Save failures: 0
     - "Data on phone" with the MB per minute, and "Lowest free phone storage"
   - Take a screenshot of the whole proof screen. Scroll if needed.
6. **Export the zip**
   - On the proof screen, tap "Export capture files" and save or share the zip.
   - Note the zip file name (lidar-YYYYMMDD-HHMMSS-XXXXXXXX.zip).
7. **3D**
   - Back on the result screen, tap "Open LiDAR mesh in 3D". Check that the mesh opens and can be turned.
   - Pick "Photo". Wait for the photo texture and note the line under the mesh: photos used, share of the mesh, seconds.
   - Check that the photos are the right way up and note any visible seams or brightness jumps. Take a screenshot.
   - Tap "Share 3D model", save the USDZ, and open it in Files or Quick Look. Note whether the photo texture is still there.
8. **History round trip**
   - Close the result. Open History and open the same scan.
   - Open its LiDAR capture again. Check that it is the same capture, with the same time and numbers as in step 5.
   - If more than one capture is listed, check that the one with the most keyframes is selected (if two have the same number, the longer one).

## Report

Post in #LiDAR:
- the git sha, the phone model and the iOS version
- the zip name, with the zip attached
- screenshots from steps 1, 3, 5, 7 and 8
- any step that did not behave as written above, with the step number

Pass means every step behaved as written. Anything else is a fail for that step, even if the rest passed.
