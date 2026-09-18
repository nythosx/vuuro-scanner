Phone review on 9e0fc06. Full notes + 17 screenshots are on Momenta card LIDAR-17. Please open that card and work from the shots, not this summary. Diagnostics log attached here.

One product note, because you asked: preparing the UI as if this could go public is useful, and it shows. The app already looks and feels a lot better because you picked that up without waiting. Thank you for that. For now we will move forward to first starting to use it ourselves first (admin, to be linked to our real estate platform / internal test scans) until the product is actually used, thought through, and solid enough that a wider release is worth it. Store-ready polish is welcome as a side effect, not the current goal. Device reliability and the list below come first.

Worked: add note, Share PDF, Share image. The "Scan interrupted / World tracking failure" screen itself recovered cleanly (Upload what was captured). That interrupt is not a bug to chase.

Please fix first:

Save image: white screen, app hangs (same class as the earlier QuickLook hang).
Terms/Policy, Activity log, and the in-app PDF viewer: no Close/Done. I have to force-quit.
Notes: cannot take a new camera photo, library only.
VS-NOTE_ADD-ERR: raw Swift.CancellationError in the Dutch UI, dressed as a "spotty connection". Your cancellation-as-not-an-error fix does not cover this path.
Then the live capture HUD, this is what actually broke the scan:

Progress ring stuck at 95% and never reaches 100%. AREA stayed 0.0 m2 the whole time while walls and height did update (8 then 12 walls, height 3.1 to 3.5 m). After upload the same room is 53.5 m2. I kept scanning because the HUD said "almost done" and "no area yet", then tracking died. Say what the % measures, or do not show a number that looks like completion. Live m2 has to move during capture.
Tap the floor-plan image still does not zoom.
Also:

Onboarding copy is clipped on the left (only "flow", "perty professionals", "...extra hardware required.").
Doublecheck spacing on labels run together on device ("Finishroom", "Scaninterrupted").
Result screen badges a single room as FUSED while the sheet says rooms are not laid out relative to each other. Pick one truth.
Dark mode toggle lags vs the other toggles on Settings.
Sign out is there even though I never signed in.
App icon is still the placeholder in Spotlight.
SHA + GitHub Actions compile run on that exact commit, P0s first. I will retest after your fixing of these items on LIDAR-17 (

https://momentamonster.com/board/projects?task=LIDAR-17) and your "Ready to test" full update (incl. other items you mentioned) and release.

Today
M
Mark
19:24
Not a fully aligned correct start screen.

screenshot-2026-09-18-132445.png
screenshot-2026-09-18-132450.png
screenshot-2026-09-18-132455.png
🙂+
What is the % indicating? User might think almost full room done (which is not the case)

screenshot-2026-09-18-132510.png
🙂+
I never manage to get it to 100% so I am not sure now when to set it “Done” while I think I am about ready with this room.

And the m2 is not counting in any way.

screenshot-2026-09-18-132529.png
🙂+
After taking previous screenshot, capture errored

screenshot-2026-09-18-132545.png
🙂+
Add note works
Take and add a new picture isn’t

screenshot-2026-09-18-132703.png
🙂+
Got an error…

screenshot-2026-09-18-132714.png
🙂+
I am tapping the image, expecting to zoom in - but that’s not working

screenshot-2026-09-18-132724.png
🙂+
Not clear on how to exit this PDF viewer in-app

screenshot-2026-09-18-132738.png
🙂+
Save image and got white screen / app halts

screenshot-2026-09-18-132747.png
🙂+
Toggle dark mode not responsive enough (the other toggles in this screen are)

screenshot-2026-09-18-132759.png
🙂+
In app settings, choose Terms / Policy and cannot exit this screen anymore.

Now I need to restart the app again.

screenshot-2026-09-18-132810.png
🙂+
Share PDF and image seems to work properly

screenshot-2026-09-18-132828.png
🙂+
With viewing log cannot exit screen as well, need to restart the app again then.

screenshot-2026-09-18-132839.png
🙂+
Sign out functionality, but I didn’t sign inwith any account I believe?

screenshot-2026-09-18-132850.png
🙂+
Apply Vuuro Scan app icon

screenshot-2026-09-18-132900.png
🙂+
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132900.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132839.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132828.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132810.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132759.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132747.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132738.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132724.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132714.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132703.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132545.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132529.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132510.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132455.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132450.png"
"C:\Users\Acer\Downloads\screenshot-2026-09-18-132445.png"
