# Gallery format

The gallery is a folder in the app's Application Support directory (`Lightbox/Gallery`; on the Mac inside the app's sandbox container, see *Settings → Show in Finder*). Code: `LightboxCore/Gallery.swift`, compositions in `LightboxCore/Composition.swift`.

```
Gallery/
  index.json          folders and pictures
  images/<id>.png     the picture as ComfyUI made it
  thumbs/<id>.jpg     a copy whose longer side is 512 px; made again if missing
  guides/<name>       guide pictures, by the file name the recipes use
  workflow-runs/<name>.json  the node-editor workflow pictures were made with
  workflows/
    index.json        the node editor's workflows: names and dates
    <id>.json         a workflow, as ComfyUI saves it
  compositions/<id>/
    composition.json  canvas and layers
    layers/<image>.png each layer's picture
```

## index.json

```json
{
  "version": 1,
  "folders": [{ "id": "…", "name": "Foxes", "created": "2026-11-24T16:00:00Z", "parentID": "…" }],
  "items": [
    {
      "id": "…",
      "folderID": "…",
      "date": "2026-11-24T16:05:00Z",
      "width": 832,
      "height": 1216,
      "recipe": { … },
      "source": "…",
      "edge": 0.5,
      "composition": "…",
      "tags": ["Lisbon", "night"],
      "workflow": { "workflowID": "…", "name": "Foxes", "file": "3f2a….json", "node": "9", "server": "…" }
    }
  ]
}
```

- `items` is newest first. `folderID` is missing for pictures in no folder.
- Folders are a field of each picture, so moving a picture changes only the index. A folder's `parentID` is the folder it is in (missing = at the top); a folder is never inside itself. Deleting a folder moves its pictures and folders into its parent (or to the top).
- `tags` (optional) are words to find and group pictures by. Tags that differ only in case are the same tag.
- `source` and `edge` are set only for cut-outs (*Remove Background*): the picture it was cut from, and how tightly (0 soft … 1 tight). A cut-out has the same recipe as its original.
- `composition` is set only for a flattened composition (*Save to Gallery* in the editor): the composition to edit again. Its recipe is the bottom layer's that has one.
- `workflow` (optional) is set only for pictures made in the node editor: the library workflow it was run from (`workflowID`, missing if it was never saved), its name, the run file in `workflow-runs/`, the output node the picture came from (API id) and the server. The run file is `{"workflow": <UI format>, "prompt": <API format>}`, named by its content, so the pictures of one run share it; it is deleted once no picture uses it. Such a picture's `recipe` holds what `WorkflowImport` could read from the prompt, with the prompt texts as sent.
- `recipe` is a `GenerationRecipe`: the preset as it was (with the size actually used), the prompt and negative as typed, extra LoRAs, the camera/light/film or comic styles used (`modifiers`, as they were then), content rating, face/hand fix settings, the guides (kind, strength, timing, whether the picture was extracted first, and its file in `guides/`), seed, the picture's place in its batch, the prompt as sent to ComfyUI, the detectors used, and the server.
- Several pictures can share a guide picture. Deleting pictures deletes a guide picture once no remaining recipe uses it.
- Dates are ISO 8601. Fields added later must be optional or have a default, so older galleries still load. Raise `version` only for changes older apps can't read; they refuse a newer version instead of overwriting it.

## Compositions

```json
{
  "version": 1,
  "id": "…", "name": "Two foxes",
  "created": "…", "modified": "…",
  "width": 1216, "height": 832,
  "background": "transparent",
  "grayscale": false,
  "output": "…",
  "guides": [{ "id": "…", "axis": "vertical", "position": 608 }],
  "layers": [
    {
      "id": "…", "name": "Fox",
      "image": "…", "pixelWidth": 832, "pixelHeight": 1216,
      "frame": { "x": 0, "y": -100.5, "width": 832, "height": 1216 },
      "opacity": 1, "grayscale": false, "visible": true,
      "source": "…", "recipe": { … },
      "edits": [{ … }],
      "shadow": { "style": "cast", "angle": 35, "distance": 0.35, "blur": 0.015, "opacity": 0.45 }
    }
  ]
}
```

- `layers` is bottom to top. `frame` is in canvas pixels, y going down, and isn't rounded.
- A layer has its own copy of its picture (`layers/<image>.png`), so deleting or changing the gallery picture doesn't change the composition. The magic wand writes a new `image` instead of changing the file; files no layer uses are deleted on the next save.
- `edits` (optional) lists the parts painted again with *Edit with Model*, oldest first, each as a `GenerationRecipe` (preset, prompt as typed and as sent, seed).
- `shadow` (optional) is made from the layer's visible pixels: `drop` (offset by `angle` in degrees and `distance`) or `cast` (on the ground from the lowest visible point, leaning by `angle`, `distance` long; negative falls towards the viewer). `distance` and `blur` are shares of the layer's height. It is drawn under the layer, with the layer's opacity.
- `background` is `transparent`, `white` or `black`. `grayscale` makes the whole picture gray; a layer's `grayscale` only that layer.
- `guides` (optional) are the guide lines dragged out of the rulers: `vertical` ones at an x, `horizontal` ones at a y, in canvas pixels.
- `output` is the gallery picture the last *Save to Gallery* wrote. Each save adds a new picture; earlier ones stay.
- `version` works as in `index.json`.

## Workflows

`workflows/<id>.json` is a plain ComfyUI workflow (UI format, schema 0.4 or 1, as it was opened), so it can be copied out and opened in ComfyUI. `workflows/index.json`:

```json
{ "version": 1, "workflows": [{ "id": "…", "name": "Foxes", "created": "…", "modified": "…", "presetID": "…" }] }
```

`presetID` (optional) is the preset the workflow belongs to; it is missing for workflows kept after their preset was deleted. Nodes Lightbox manages carry their part of the generation in `properties.lightbox_role` (e.g. `"sampler"`, `"lora:styles/ink.safetensors"`); ComfyUI keeps it.

Fields Lightbox doesn't know (from newer ComfyUI frontends or custom nodes) are kept when a workflow is saved again. Code: `LightboxCore/WorkflowStore.swift`, `ComfyKit/WorkflowDocument.swift`.
