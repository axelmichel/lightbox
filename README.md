# Lightbox

A Mac and iPad app for generating pictures with a ComfyUI server and keeping them in a gallery. Every picture is stored with everything it was made with, so it can be explained and made again.

## Using it

- **Connect:** enter the server's address under Settings (⌘, on the Mac, the gear on the iPad), e.g. `192.168.1.20:8188`. On the first connection Lightbox makes a preset for every checkpoint on the server.
- **Presets:** *Edit Presets…* on the Generate panel. Lightbox looks at each checkpoint and suggests its settings. It reads the file name, the details stored in the file (architecture, the model it was trained from, its training tags), and the LoRAs in use. From these it picks:
  - the family: SD 1.5, SDXL, Pony, Illustrious/NoobAI, Flux, Flux 2 (Klein), Z-Image, or unsupported (SD3, HiDream and others);
  - the style: *Anime / Comic*, *Photo* or *Illustration / Art*;
  - the speed: Lightning, Turbo, Hyper or LCM, with their step counts.

  The preset then gets a matching sampler, steps, CFG, CLIP skip, size, prompt style (tags or sentences), quality terms and negative prompt. *Why these settings* lists what each guess was based on. Every value can be changed; *Suggest Settings* runs the detection again, e.g. after adding a Hyper LoRA.
- **Prompt:** the prompt and the negative are tabs in the panel under the gallery. Drag the bar above it to make it taller or shorter. The thumbnail size is set at the top right of the gallery.
- **Styles:** next to *Generate*, photo presets offer one *Camera*, *Light* and *Film* style each, and anime and illustration presets a *Comic Style*. Their terms are added after the prompt. *Edit Styles…* changes them or adds your own. A style's preview is made with *Render Preview* (a small picture on the server) or picked from the gallery (*Choose from Gallery…*, or *Use as Style Preview* in a picture's context menu).
- **Prompt helper:** *Enhance* rewrites the prompt with a local language model (Ollama) in the way the preset's model wants: Danbooru tags for Illustrious and Pony, sentences for photo models. It leaves out what Lightbox adds anyway (style terms, styles, trigger words). An optional wish (“make it rainy”) and a per-preset hint (in the preset editor) steer it. The rewrite is shown first: *Use* puts it into the prompt (*Undo* brings the old one back). Set it up under *Settings → Prompt Helper*: install [Ollama](https://ollama.com), run `ollama pull qwen3:8b` (or another model), and pick the model.
- **Generate:** pick a preset, write a prompt, press *Generate* (⌘↩). The Generate panel has the size (pick a format such as 3:2 or 16:9 and Lightbox uses the size the model was trained for), the number of pictures per run, the seed (empty = random), guides, extra LoRAs (with a separate prompt strength under *More*) and the face/hand fix (if Impact Pack is installed). *Sent to ComfyUI* shows the full prompt as it will be sent.
- **LoRA info:** the puzzle-piece button (next to *Add LoRA* in the Generate panel and the preset editor, or a LoRA's *More*) lists the server's LoRAs. Each starts with what its file says (trigger words, family, strength) and has room for notes, a link and a sample prompt. Once edited, its trigger words and strength are what picking the LoRA fills in.
- **Flux, Flux 2 and Z-Image:** these come as separate files: the diffusion model (also GGUF), text encoders and a VAE. Lightbox makes a preset for each diffusion model on the server and picks the text encoders (Flux: T5 and CLIP-L; Flux 2 Klein: Qwen3 8B for 9B, 4B for 4B; Z-Image: Qwen3 4B) and the VAE (`ae`, for Flux 2 `flux2-vae`) by their names; the preset editor shows them. Flux uses *Guidance* instead of CFG and has no negative prompt; Z-Image has a sampling *Shift*; Flux 2 samples with its own schedule for the picture's size (Klein: 4 steps, CFG 1). Guides (ControlNet, IP-Adapter) don't work with them yet; *Edit with Model* and *Redraw Area* do, and the face/hand fix does except with Flux 2.
- **Import a workflow:** *Edit Presets… → + → Import ComfyUI Workflow…* reads a workflow `.json` (saved or exported in API format) into a new preset: checkpoint or diffusion model with its text encoders, LoRAs, sampler, steps, CFG, Flux guidance, sampling shift (also from custom sampling: `SamplerCustomAdvanced` with its guider, sampler and scheduler), size, CLIP skip, VAE and negative. The workflow's prompt goes into the prompt field. *Why these settings* lists what was taken from where, and the nodes that weren't taken over (upscalers, detailers, ControlNets).
- **Choosing LoRAs:** *Add LoRA*, or the LoRA button in a LoRA row, opens the LoRA Info page as a chooser: search by name, trigger word or note, see each LoRA's picture, family and notes, and press *Use This LoRA* (or double-click it). It first shows only the LoRAs made for the preset's model family, with those whose family isn't known below; *All* at the top shows every LoRA, those for another family marked. Each LoRA can have a picture: *Choose from Gallery…* or *Choose File…* on its info page, *Use as LoRA Picture* in the context menu of a picture made with it, or *Look Up on Civitai*, which adds a safe example picture if there is none.
- **LoRAs:** picking a LoRA reads its file: the trigger words are filled in, other telling training tags can be added with a click, and the strength starts at a value for its kind (detail 0.6, style 0.8, otherwise 1). A LoRA trained for another model family than the preset's is pointed out. *More* lists what each guess was based on.
- **Guides:** *Add Guide…* on the Generate panel, or *Use as Guide* on gallery pictures (several at once work too).
  - *Shape the image* (ControlNet): scribble, line art, soft or hard edges, depth, surfaces, pose, unblur. The lines, depth or pose are extracted from the picture first, unless it already is such a map.
  - *Borrow from a picture* (IP-Adapter): reference, style, composition.

  Each guide has a strength and a timing (which part of the steps it acts on). Lightbox picks the model for the preset's family. *Settings* lists which guides the server can do and what is missing.
- **Remove Background** (context menu or full view): adds a cut-out next to the picture, made on the device with Vision. In the full view, the *Edge* slider cuts it again more softly or tightly.
- **Compose:** put several gallery pictures together on one canvas. *New Composition* in a picture's context menu (with several selected, all of them; the oldest goes lowest) or the layers button under the sidebar. The composition opens in the main area and is listed under *Compositions* in the sidebar; it is saved on its own.
  - *Layers* (right): drag to reorder, the eye hides one. Each layer has an opacity, *Grayscale*, a size, *Fit*/*Fill*/*100 %* and *Remove Background*. With no layer selected the panel shows the canvas: size (with formats such as 3:2), *Fit Canvas to Layers*, background and *Whole Picture in Gray*.
  - *Tools* are on a vertical bar over the canvas; drag it by its grip to put it anywhere. Keys: V move, W magic wand, B brush, M area. It also has *Undo* and *Redo* (⌘Z, ⇧⌘Z) and *New Layer*.
  - *Add Layer* (+ in the layer panel's header): an empty layer the size of the canvas (above the selected one), pictures from the gallery, or picture files (PNG, JPEG, HEIC, …), which can also be dropped on the canvas. Imported pictures are turned upright; a composition made only of them is saved to the gallery without a prompt.
  - *Move* tool: drag a layer to move it, its corners to resize it (⇧ changes the proportions), arrow keys nudge it (⇧ 10 px), also right after picking it in the layer list, and several selected layers together.
  - *Rulers* (⌘R) along the top and left: drag out of a ruler to make a guide line, drag a guide to move it, drop it back on its ruler to remove it (right-click the corner removes all). Guides are saved with the composition. *Grid* (⌘') fades in over the canvas; right-click its button for the size and to turn snapping off. While moving or resizing, layers snap to the grid, the guides and the canvas's edges and center; hold ⌘ to place them freely.
  - The layer panel and the Generate panel each close with the button at the right of their own header; while closed, that button is in the header now at the right edge, at the same height, and opens it again.
  - *Magic Wand* tool: click a layer to select pixels of a similar color (⇧ adds, ⌥ subtracts) and set the tolerance. *Brush* tool: paint the selection by hand (⌥ or *Erase* takes away). *Delete Selection* (⌫) makes the selected pixels transparent. The gallery picture stays as it is.
  - *Merging layers:* select the layers to merge in the layer list (⌘-click or ⇧-click), then *Merge N Layers* in the context menu, or *Merge Layers* (⌘E) in the panel. The merged layer is drawn as the layers look (opacity and gray included) at canvas pixels, in the lowest one's place, so the magic wand, the brush and *Edit with Model* work across what was several layers. Hidden layers in the selection stay out of it. Several selected layers can also be deleted together; ⌘Z undoes either.
  - *Shadow* (layer settings): a shadow made from what the layer shows, so cut the subject out first (*Remove Background* or the magic wand). *Drop Shadow* falls behind it (direction, distance); *Cast Shadow* lies on the ground from the layer's lowest visible point (lean, length; negative lengths fall towards you). Softness and opacity for both. It doesn't change the layer's pixels and is saved, merged and flattened as shown.
  - *Edit with Instruction* (canvas settings, or with an area): the whole picture goes to a Flux 2 (Klein) preset with what should change, e.g. "add a soft shadow of the woman on the floor, light from the left" or "make it evening". The model sees the whole scene, so shadows and light fit it. The result is a new layer on top, or with an area and *Only inside the area* just that part with a soft edge.
  - *Area* tool (M): drag a rectangle or ellipse (⇧ for a square or circle) over any part of the picture, then *Redraw Area* (layer panel) with what should be there. That part of the whole picture, all visible layers together, goes to ComfyUI; the result becomes a new layer on top with a soft edge, so nothing below changes. Each try adds a layer; delete the ones you don't want. Esc or a click clears the area.
  - *Edit with Model* (layer panel): paints the selected part of one layer again with ComfyUI, following what you write (e.g. "a red scarf"). Pick the preset (the layer's own by default) and the strength: low keeps the shapes and colors, 100 % paints the part anew, which also fills transparent holes. Only the selection and some room around it is sent, at the size the model works best at; the rest of the layer keeps its pixels. The selection stays, so *Paint Selection Again* gives another try, and ⌘Z goes back.
  - Everything can be undone (⌘Z). *Save to Gallery* (in the layer panel's canvas settings, shown with no layer selected) adds the flattened picture to the gallery; each save adds a new one. *Edit* on such a picture opens its composition again.
- **Gallery:** new pictures land in the folder that is shown (or in no folder while *All Pictures* is shown). Make folders with *New Folder* (inside the folder shown) or *New Folder Inside* in a folder's context menu; drag a folder onto another to put it inside, onto *All Pictures* to bring it to the top. Drag pictures onto a folder or use *Move to* in the context menu. On the Mac, ⌘-click or ⇧-click selects several. Delete removes the picture files (after asking).
- **Tags:** *Tags…* in a picture's context menu (several at once work too) or the info panel of the full view. Type a tag and press Return (commas separate several), or click one of the gallery's tags; × takes one off. The sidebar lists all tags with their counts: click one to see its pictures, drop pictures on it to tag them, right-click to rename (a used name merges) or delete it.
- **Search:** the search field in the gallery's bar (⌘F) finds pictures by every word in their prompt, negative, preset, model, LoRAs, seed or tags; `#word` looks only in the tags, "quoted words" are found together. It searches the folder or tag shown, or *All Pictures*.
- **Full view:** double-click (Mac) or tap (iPad) a picture. Step through the pictures with ← →, the side buttons, a swipe, or the strip at the bottom. Pinch or double-click to zoom. The info panel shows the prompt as typed, the prompt as sent, and all settings.
- **Reuse:** *Use Settings* (info panel or context menu) fills the Generate panel with the picture's preset, size, prompt, negative, guides (with their pictures), LoRAs, face/hand fix and seed. *New Seed* does the same with a random seed, and *Use Seed* sets only the seed. A deleted preset is added back from the picture. *Copy All Settings* copies them as JSON.
- **Content rating** (Settings): *All ages*, *Teen* or *Mature* decide which sexual terms are allowed. Sexual content involving minors is refused at every rating.

## Requirements

- Xcode 27 / Swift 6, macOS 14+ or iPadOS 17+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to regenerate `Lightbox.xcodeproj` after changing `project.yml`
- A ComfyUI server on the network, started with `python main.py --listen`. Add `--preview-method auto` for live previews while sampling.
- Checkpoints that `CheckpointLoaderSimple` can load: SD 1.5 and the SDXL family (Pony, Illustrious, …). Flux.1 (dev, schnell, Krea), Flux 2 Klein and Z-Image as diffusion models with their text encoders and VAE; GGUF files need [ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF). SD3 and other models are detected but not supported yet.
- Optional, for guides: ControlNet and IP-Adapter models, comfyui_controlnet_aux (extracting lines, depth, pose) and ComfyUI_IPAdapter_plus. A Krita AI Diffusion server setup has all of them.
- Optional, for the prompt helper: [Ollama](https://ollama.com) on the Mac (or anywhere on the network) with a chat model, e.g. `qwen3:8b` or `llama3.2:3b`.
- Optional: ComfyUI-Impact-Pack and Impact-Subpack with `bbox/face_yolov8m.pt` / `bbox/hand_yolov8s.pt` for the face and hand fix.

## Run

```
xcodegen            # only after editing project.yml
open Lightbox.xcodeproj
```

**Mac:** select the `Lightbox` scheme and *My Mac*, then Run.

**iPad:**
1. Connect the iPad and select it as the run destination.
2. Set up signing once (see [Signing](#signing)). A free Apple ID works.
3. Turn on *Settings → Privacy & Security → Developer Mode* on the iPad.
4. Run, and allow local network access when asked.

## Signing

The signing team isn't stored in the project. Each checkout keeps it in `Config/Local.xcconfig`, which git ignores:

```
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Put your Team ID into it (`DEVELOPMENT_TEAM = …`). Set your own `PRODUCT_BUNDLE_IDENTIFIER` there too.

## Checks

```
(cd Packages/LightboxCore && swift test)
(cd Packages/ComfyKit && swift test)
(cd Packages/LightboxUI && swift test)
xcodebuild -project Lightbox.xcodeproj -scheme Lightbox -destination 'platform=macOS' build
xcodebuild -project Lightbox.xcodeproj -scheme Lightbox -destination 'generic/platform=iOS Simulator' build
swift format lint -r App Packages
```

The ComfyKit server tests run only when `COMFY_URL` is set. They generate small 512² images. `COMFY_CHECKPOINT` picks the model; otherwise the server's first checkpoint is used.

To test without a GPU, use the fake server in `tools/fake-comfyui`. It speaks ComfyUI's protocol and returns tiny dummy images:

```
python3 -m venv /tmp/fake-comfy && /tmp/fake-comfy/bin/pip install -r tools/fake-comfyui/requirements.txt
/tmp/fake-comfy/bin/python tools/fake-comfyui/fake_comfy.py Packages/ComfyKit/Tests/ComfyKitTests/Fixtures/object_info.json 8189
(cd Packages/ComfyKit && COMFY_URL=127.0.0.1:8189 swift test)
```

The app can connect to it too (`127.0.0.1:8189`).

## Layout

- `App/`: the `@main` entry only.
- `Packages/ComfyKit`: the ComfyUI client: `/object_info` catalog, workflows built in code, upload, queue, WebSocket progress, model metadata. Depends on nothing.
- `Packages/LightboxCore`: presets and preset detection, prompt composition with the content guard, recipes, and the gallery on disk. No SwiftUI.
- `Packages/LightboxUI`: the SwiftUI app.
- `docs/GALLERY_FORMAT.md`: how the gallery is stored.

ComfyKit has no app-specific code and can be used on its own.
