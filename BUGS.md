# Vuuro Scan v1 - Walkable Spatial Tour

Prepared for handoff. Target: iOS capture app plus web viewer. Scope is photos, hotspots, plan and dollhouse. No mesh, no splats.

## Goal

A renter or buyer opens a URL, walks through the home online room to room using photos and hotspots, sees the floor plan and dollhouse as context, and gains enough trust in layout, condition and scale that an onsite viewing is often unnecessary.

Capture is iPhone only. RoomPlan provides geometry. HDR photos provide realism. No GPU server, no dense mesh, no splats.

## What is in v1

- RoomPlan capture, unchanged from today
- New per room HDR photo capture step
- New 360 hotspot navigation
- Plan and dollhouse view with hotspot markers
- Full screen 3D view with layer filter and theme toggle
- Web viewer using Three.js
- Embeddable on the listing site

## What is not in v1

- Dense mesh output
- Gaussian splats
- Photo baked textures on walls
- Server side GPU processing
- Realistic 3D furniture models (see v1.1)
- AR furniture placement

## iOS capture flow

Existing flow stays. RoomPlan room scanning, save and next, finish unit. One new step is added.

After each room is saved, before the next room starts, the app prompts for photos.

### Photo capture step

- Screen title: Photos for this room
- Instruction: Take 15 to 20 photos covering the whole room. Slow pan, one photo every two steps. Cover corners, walls, floor, ceiling.
- Live counter shows photos taken and minimum required
- A small minimap shows which directions have been covered and which are missing
- User can skip and take photos later, but upload is blocked until minimum is met
- Photos are stored locally with the room identifier until upload

### Photo requirements

- Minimum 15 photos per room
- Maximum 30 photos per room
- JPEG at highest quality the device offers
- No file over 8 MB after compression
- Each photo tagged with capture position from ARKit at the moment of shutter
- Each photo tagged with camera orientation from ARKit

### Upload

Same upload flow as RoomPlan data. Photos go to Scan Service in the same session, tagged by room identifier. Idempotent per photo using a client side key.

## Full screen 3D view

A new full screen presentation of the dollhouse. Opened from the result screen by tapping the 3D preview or by a dedicated button.

### Layout

- Full screen canvas
- Top bar, transparent, sits over the canvas
  - Left: close button, returns to the result screen
  - Center: room title or unit title
  - Right: theme toggle, light or dark
- Bottom bar, transparent, sits over the canvas
  - Left: mode segment, Dollhouse or Cutaway
  - Right: layer filter button, opens a side panel

### Layer filter panel

Slides in from the right. Same style as the Layers panel in the reference screenshot.

Rows, each with an eye icon that toggles visibility:

- 3D Floor Plan (walls and floors)
- Doors
- Windows
- Openings
- Furniture
- Ceiling
- Room labels
- Hotspot markers

Tapping an eye icon hides or shows that category. State is per session, not saved.

### Camera

- One finger drag rotates
- Two finger drag pans
- Pinch zooms
- Double tap resets camera to default framing
- Default framing is the same placeDefault angle used today, yaw at 45 degrees, pitch at 45 degrees, distance is max size times 0.9 plus 2

### Theme toggle

- Light theme: background is off white, walls are light grey, doors are orange, windows are blue, floor keeps room type colors. This matches the reference image sent by the client.
- Dark theme: background is near black, walls are dark grey with subtle edges, doors and windows keep their colors, floor keeps room type colors. This matches the current app output.
- Theme is a presentation choice, not a system preference. Default is light for the full screen view.
- Toggle state persists across sessions using AppStorage

### What is on the canvas

- RoomPlan walls, floors, doors, windows, openings
- Furniture bounding boxes from RoomPlan
- Room labels floating over each room
- Hotspot markers, small circles, one per captured photo position

Tapping a hotspot marker opens the web viewer at that photo, or opens an in app preview if the web viewer is not reachable.

## Fixes carried into v1

### Corner gaps

Current output shows visible gaps at corners where two walls meet. The fix is to weld outline vertices at shared points before mesh generation. Every outline point that is within one millimetre of another becomes one vertex. Both adjacent walls share the welded vertex.

### Doors as holes

Current output draws the full wall then places a door box on top. Doors are not cut through the wall. The fix is to subdivide the wall along its length into segments, one for each opening plus one for each solid span between openings. Each opening becomes a real hole in the wall.

Same treatment applies to windows and other openings.

### Multi floor merge

Current output stacks floors vertically with a gap. No UI to select a floor. The fix is a floor selector in the full screen view, a small segmented control above the bottom bar. Default is All floors, which keeps the current stacked view. Selecting a floor isolates that floor and hides the others.

## Web viewer

A separate deliverable, hosted on the Scan Service.

### Technology

- Three.js for 3D
- Pannellum or Marzipano for equirectangular panoramas
- Single page, no framework, served as static assets plus a small JSON config per session

### URL structure

- One URL per session, for example `https://scan.vuuro.nl/tour/{session_id}?token={access_token}`
- The URL is shareable and embeddable in an iframe

### Layout

- Full viewport canvas
- Bottom left: minimap, top down floor plan, current position dot
- Bottom right: room name and photo counter
- Top right: menu with plan, dollhouse, and photo tour options
- Hotspots are drawn on the panorama as small circles, tapping them moves to the next photo

### Navigation

- Primary: photo tour, room to room using hotspots
- Secondary: minimap click, jumps to nearest photo in the target room
- Tertiary: dollhouse overview, click a room to jump in

### Loading

- Low resolution floor plan loads first
- Panoramas load per room, on demand
- Adjacent rooms preload in the background

### Embedding

- Iframe friendly, no scrollbars, no branding inside the embed
- Host site controls sizing
- Session data comes from a JSON endpoint, no server rendering required

## Data model additions

### Photo set per room

Add to the FloorPlan contract:
photos_360: [
{
photo_id: string,
room_id: string,
url: string,
position_m: [x, z],
heading_deg: number,
captured_at: string
}
]

text

### Session tour metadata

Add to the session response:
tour: {
viewer_url: string,
plan_image_url: string,
dollhouse_glb_url: string
}

text

## Out of scope for v1, planned for v1.1

- Realistic 3D furniture via pre made model library
- Photo texture projection on walls and floors
- Room by room photo stitching into 360 panoramas (v1 can use flat photos in a sequence instead)
- AR furniture placement in the scanned room
- AI staging and renovation previews
- AI property assistant using retrieval over listing data