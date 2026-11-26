# Node-Editor: Implementierungsplan

Stand: 2026-11-25. Dieser Plan beschreibt nur das Vorgehen; es ist noch nichts umgesetzt.

## 1. Ziel

Der Generate-Bereich bekommt zwei Ansichten auf denselben Zustand: den bisherigen Konfigurator und einen
Node-Editor nach dem Vorbild von ComfyUI. Beide sind gekoppelt:

- Preset wählen → der Graph zeigt die passenden Lader, Sampler und Werte.
- LoRA im Konfigurator hinzufügen → ein `LoraLoader` erscheint in der Kette.
- LoRA im Graphen einhängen oder Wert im Graphen ändern → der Konfigurator zeigt es an.

## 2. Entscheidungen aus der Klärung

| Thema | Entscheidung |
|---|---|
| Kopplung | Hybrid: erkannte Teile bleiben in beide Richtungen gekoppelt, freie Ergänzungen laufen mit; der Konfigurator zeigt „angepasster Workflow“. |
| Umfang v1 | Kern: anzeigen, verschieben, zoomen, Werte ändern, verbinden, Knoten hinzufügen/löschen, ausführen. Gruppen, Subgraphs, Reroutes, Copy/Paste später. |
| Prompt | Text-Knoten zeigen den fertig zusammengesetzten Prompt (`compose()`), im gekoppelten Zustand gesperrt. Geändert wird er nur im Prompt-Feld. |
| Plattform | Erst Mac (Maus, Trackpad, Tastatur). iPad-Touch ist ein eigener späterer Schritt; der iOS-Build muss aber immer kompilieren. |
| Speicherort | Benannte Workflows im `WorkflowStore`, die auf ein Preset verweisen; mehrere pro Preset. |
| Abdeckung | Der Graph ist genau das, was gesendet wird, inkl. Guides und Gesichts-/Hand-Fix. Der Rückweg kommt schrittweise. |
| Einbindung | Umschalter „Konfigurator / Nodes“ in Generate; Prompt-Feld und Generieren bleiben sichtbar. |
| Rückweg | Preset-Werte, die im Graphen geändert werden, sind eine Abweichung im Workflow. Das Preset bleibt unverändert; „Ins Preset übernehmen“ und „Zurücksetzen“ im Konfigurator. LoRAs aus dem Graphen landen bei den Zusatz-LoRAs. |
| Preset-Wechsel | Der Modellteil wird umgestellt, Ergänzungen bleiben. Bei anderer Bauform (Checkpoint ↔ Split-Modell, anderes Sampling) wird gefragt. |

## 3. Ausgangslage

Vorhanden und mit Tests abgedeckt (ComfyKit, LightboxCore):

- `WorkflowDocument` / `NodeGraph`: ComfyUI-UI-Format lesen und schreiben, unbekannte Felder bleiben erhalten.
- `WidgetLayout`: `widgets_values` ↔ Eingänge laut `/object_info`.
- `WorkflowEditing`: Knoten hinzufügen/entfernen, verbinden, trennen, Typprüfung.
- `WorkflowCompile`: Dokument → API-Format, inkl. `texts` und `loraNames` für den Content Guard.
- `ApiLayout`: API-Graph → Dokument mit Slots und automatischem Spalten-Layout.
- `WorkflowRun`: beliebigen Graphen ausführen, Ereignisse pro Knoten.
- `WorkflowStore`: Workflows als Dateien mit Index.

Der Konfigurator-Weg: `GenerationPreset` + Sitzung → `compose()` → `GenerationPreset.request` →
`WorkflowBuilder.txt2img` → API-Graph. Kein Layout, kein Rückweg.

Entfernt (im Arbeitsstand gelöscht, in der Git-Historie noch vorhanden): die Editor-Oberfläche, etwa 2.400 Zeilen in
fünf Dateien. Sie war ein eigenständiger ComfyUI-Klon ohne Kopplung; die einzige Brücke war „Make a Preset“.
LightboxUI hat kein Test-Target.

Nicht geprüft: Ich habe weder gebaut noch die Tests laufen lassen, und die Absturzursachen des alten Versuchs
nicht untersucht. Schritt 0.2 holt die Baseline nach; der Plan hängt nicht von der Ursachenanalyse ab.

### Lehren für diesen Anlauf

1. Der alte Versuch baute die ganze Oberfläche auf einmal, ohne dass je ein Zwischenstand lief. Hier ist jeder
   Schritt für sich lauffähig und wird von dir in der App abgenommen.
2. Die schwierige Aufgabe ist die Abbildung Preset ⇄ Graph, nicht die Zeichenfläche. Sie wird zuerst gelöst, als
   reine Funktionen mit Tests, bevor irgendeine Editor-Interaktion existiert.
3. Logik gehört nicht in Views. Geometrie, Abgleich und Rückweg sind testbare Typen ohne SwiftUI.
4. Gesten (Pan, Zoom, Ziehen, Verbinden, Textfokus) kommen einzeln, jede als eigener Schritt.

## 4. Architektur

### 4.1 Begriffe

- **Verwalteter Knoten**: ein Knoten, den der Konfigurator kennt. Er trägt eine **Rolle** in
  `properties` (z. B. `checkpoint`, `lora:<name>`, `positive`, `negative`, `sampler`, `latent`, `vaeDecode`,
  `output`, `guide:<id>`, `faceFix`, `handFix`). `properties` übersteht den Round-Trip durch ComfyUI.
- **Freier Knoten**: alles ohne Rolle (Upscaler, Custom Nodes).
- **Anker**: benannte Kettenenden des Standardgraphen (`model`, `clip`, `vae`, `positive`, `negative`, `latent`,
  `image`). Freie Knoten hängen an Ankern, nicht an konkreten Knoten; wandert das Kettenende (neues LoRA),
  wandert die Verbindung mit.
- **Bauform**: die Struktur, die `WorkflowBuilder` für eine Anfrage erzeugt (Checkpoint, Split-Modell, Flux-2-Sampling).
- **Abweichung** (`PresetOverrides`): optionale Preset-Felder, die ein Workflow überschreibt.
- **Wirksames Preset**: Preset + Abweichungen des offenen Workflows. Nur dieses geht in `compose()`, Anfrage und Rezept.

### 4.2 Datenfluss: eine Richtung, ein Zustand

```
Konfigurator ─┐
              ├─► Zustand (Preset, Abweichungen, Zusatz-LoRAs, Prompt, Größe, Guides, Finish, Seed)
Node-Editor ──┘         │
   ▲                    ▼  compose() + request + WorkflowBuilder (mit Rollen)
   │              Soll-Graph
   │                    ▼  abgleichen(Dokument, Soll-Graph)
   └────────────── Dokument (Layout, freie Knoten, Verbindungen)
```

- Der Zustand bleibt die Wahrheit für alles Verwaltete. Das Dokument besitzt nur Layout, freie Knoten und deren
  Verbindungen.
- Eine Änderung an einem verwalteten Knoten im Editor verändert nicht das Dokument, sondern erzeugt eine
  **Änderung** (`GraphChange`, z. B. `steps = 30`, `zusatzLoraHinzu(name)`), die auf den Zustand angewendet wird.
  Danach läuft derselbe Abgleich wie bei einer Änderung im Konfigurator. So gibt es keinen Ping-Pong.
- `WorkflowBuilder` bleibt die einzige Stelle, die weiß, wie ein Standardgraph aussieht.

### 4.3 Wo der Code liegt

| Baustein | Paket | Grund |
|---|---|---|
| Rollen im `WorkflowBuilder`, Projektion Anfrage → Dokument, Abgleich, Anker, Lesen verwalteter Werte | ComfyKit | Arbeitet nur mit `GenerationRequest` und `NodeGraph`; mit vorhandenen Fixtures testbar. |
| `PresetOverrides`, wirksames Preset, Workflow-Bindung an ein Preset | LightboxCore | Preset- und Store-Logik. |
| `GraphChange` → Zustand, Sendepfad mit Guard, Editor-Modell, Geometrie (`NodeLayout`), Views | LightboxUI | Einziges Paket, das beide kennt; bekommt ein Test-Target. |

### 4.4 Senden

- **Standard** (kein gespeicherter Workflow, keine freien Knoten): unverändert über `client.generate` und
  `WorkflowBuilder`. Der erprobte Weg wird nicht angefasst.
- **Angepasster Workflow**: Bilder hochladen → abgleichen → `WorkflowCompiler.compile` → jeder Text aus
  `CompiledWorkflow.texts` durch `ContentGuard.check` (mit LoRA-Namen), `addNegative` für erzwungene Negative →
  `client.run`. Probleme des Compilers werden am Knoten angezeigt, nichts wird gesendet.
- Invariante, die beide Wege zusammenhält: `compile(projektion(anfrage))` ergibt denselben Graphen wie
  `WorkflowBuilder.txt2img(anfrage)` (bis auf Knoten-IDs).

### 4.5 Regeln im gekoppelten Workflow

- Gesperrt: Prompt-Texte, Guide-Bilder. Änderbar über den Konfigurator.
- Unverzichtbare verwaltete Knoten (Lader, Text-Encoder, Sampler, Decode, Ausgabe) lassen sich nicht löschen.
- Optionale verwaltete Knoten löschen = Einstellung ausschalten (LoRA entfernen, Clip Skip 1, Fix aus, Guide weg).
- Ein unbenutzter `LoraLoader`, der in die Modellkette gehängt wird, wird als Zusatz-LoRA übernommen.
- Stärke eines Preset-LoRAs im Graphen ändern = Zusatz-LoRA gleichen Namens (so rechnet `compose()` schon).
  Ein Preset-LoRA im Graphen entfernen = Abweichung „abgeschaltet“.
- Eine getrennte Pflichtverbindung zwischen verwalteten Knoten stellt der nächste Abgleich wieder her. Eine
  Verbindung von einem freien Knoten in einen verwalteten Eingang gehört dir und bleibt.

## 5. Arbeitsweise

Für jeden Schritt gilt:

1. Ein Schritt = eine Sitzung = ein Commit (nur mit deiner Freigabe). Kein Vorgriff auf spätere Schritte.
2. Vor der Abnahme grün: `swift test` in allen betroffenen Paketen, `xcodebuild` für macOS und iOS-Simulator,
   `swift format lint -r App Packages`.
3. Du nimmst in der App ab, anhand der Abnahmepunkte des Schritts. Erst danach beginnt der nächste.
4. Scheitert die Abnahme zweimal, wird der Schritt zurückgenommen und kleiner geschnitten, nicht weitergeflickt.
5. Der alte UI-Code dient nur als Nachschlagewerk (`git show <commit>:<pfad>`); er wird nicht wiederhergestellt.
6. Fixtures und Tests nur mit erfundenen Modellnamen (öffentliches Repo).
7. Richtgröße: höchstens rund 300 neue Zeilen UI-Code pro Schritt.

## 6. Schritte

### Phase 0: Fundament (keine neue Funktion)

**0.1 Arbeitsstand klären.** Die gelöschten Editor-Dateien und die übrigen offenen Änderungen committen oder
bewusst liegen lassen. Abnahme: `git status` ist so, wie du es willst.

**0.2 Baseline.** Tests beider Pakete und beide Builds ausführen, Ergebnis notieren. Fehlschläge werden vor
allem anderen behoben. Abnahme: App startet, Generieren funktioniert wie bisher.

**0.3 Test-Target für LightboxUI.** `Package.swift` um `LightboxUITests` erweitern, ein Test für
`GenerationPreset.request`. Abnahme: `swift test` in `Packages/LightboxUI` läuft.

### Phase 1: Vorwärts-Abbildung ohne Oberfläche

**1.1 Rollen im Builder.** `WorkflowBuilder` merkt sich beim Anlegen jedes Knotens Rolle und Anker; neue
Funktion liefert Graph + Rollen, `txt2img` bleibt unverändert im Ergebnis.
Tests: für Checkpoint, Flux, Flux 2, Z-Image, jeweils mit LoRAs, Guides, Fix-Pässen, Inpainting: jeder Knoten hat
eine Rolle, der Graph ist bytegleich zu vorher.

**1.2 Projektion.** Graph + Rollen → `WorkflowDocument` (über `ApiLayout`), Rollen in `properties`,
deterministisches Layout.
Tests: die Invariante aus 4.4 für dieselbe Matrix; Speichern und Laden erhält die Rollen.

**1.3 Lesen.** Aus einem Dokument die verwalteten Knoten und ihre Werte lesen (`rolle → Werte`), fehlende
Pflichtrollen melden. Tests: Lesen der Projektion ergibt die Werte der Anfrage.

Abnahme Phase 1: nur Tests; in der App ändert sich nichts.

### Phase 2: Anzeige, nur lesend

**2.1 Geometrie.** `NodeLayout` als reiner Typ: Knotengröße aus Slots und Widgets, Sockelpositionen, Trefferflächen
(LiteGraph-Maße, damit ComfyUI-Dateien gleich aussehen). Tests für Positionen und Höhen.

**2.2 Statische Ansicht.** Umschalter in Generate. Knoten als Kästen mit Titel und Sockeln, Verbindungen als
Kurven in einem `Canvas`, fest auf „alles sichtbar“ skaliert. Keine Interaktion.
Abnahme: Preset wählen → Graph erscheint; anderes Preset → Graph wechselt; LoRA im Konfigurator hinzufügen und
entfernen → Knoten erscheint und verschwindet; Split-Modell-Preset zeigt die getrennten Lader. Kein Absturz bei
schnellem Umschalten.

**2.3 Werte anzeigen.** Widget-Zeilen mit Name und Wert, gesperrte mit Schloss; Prompt-Knoten zeigt den
zusammengesetzten Prompt, bei Guard-Ablehnung den Fehler.
Abnahme: Steps, Sampler, Größe, Prompt stimmen mit dem Konfigurator überein und folgen jeder Änderung dort.

**2.4 Pan und Zoom.** Hintergrund ziehen, Pinch, Scrollrad/Trackpad, „Einpassen“. Risikoschritt: Trackpad-Scrollen
braucht unter macOS Ereignisse außerhalb von SwiftUI. Rückfallebene: Zoom-Knöpfe und Ziehen genügen für v1.
Abnahme: flüssig bei einem Graphen mit Guides und Fix-Pässen; Zoom bleibt unter dem Zeiger.

### Phase 3: Abgleich und Workflows

**3.1 Abgleich.** Reine Funktion `abgleichen(dokument, soll)`: Werte verwalteter Knoten setzen, fehlende
einfügen (Position neben dem Nachbarn), überzählige entfernen, verwaltete Verbindungen herstellen, Positionen und
freie Knoten nicht anfassen.
Tests: Position bleibt nach Wertänderung; LoRA hinzu/weg mitten in der Kette; zweimal abgleichen ändert nichts.

**3.2 Workflow-Bindung.** `WorkflowEntry` bekommt `presetID` und `PresetOverrides` (abwärtskompatibel dekodiert).
Auswahl in Generate: „Standard“ plus gespeicherte Workflows des Presets; „Als Workflow sichern“, umbenennen, löschen.
Abnahme: Workflow sichern, App neu starten, Workflow ist da und zeigt denselben Graphen.

**3.3 Verschieben und Auswählen.** Knoten ziehen, Mehrfachauswahl, Undo; Layout wird im Workflow gespeichert. Erste
Änderung des Dokuments aus der Oberfläche. In „Standard“ legt die erste Änderung automatisch einen Workflow an
(Annahme A1).
Abnahme: Layout überlebt Neustart; Änderung im Konfigurator verschiebt keine Knoten; Undo/Redo stimmt.

### Phase 4: Rückweg für Werte

**4.1 Änderungen.** `GraphChange` und seine Anwendung auf den Zustand als reine Funktion: Abweichungen
(Steps, CFG, Sampler, Scheduler, Clip Skip, Guidance, Shift, Checkpoint/VAE/Encoder innerhalb der Bauform),
Größe, Seed, Zusatz-LoRA-Stärken, Guide-Stärken, Fix-Stärken. Wirksames Preset überall einsetzen, wo bisher das
Preset gelesen wird (`compose()`, `request`, Rezept).
Tests: jede Änderung → erwarteter Zustand → erwarteter Graph.

**4.2 Werte im Graphen ändern.** Zahl, Auswahl, Schalter an verwalteten Knoten erzeugen `GraphChange`.
Risikoschritt: Textfokus gegen Zieh-Gesten und Löschtaste. Zahlen werden bei Return oder Fokusverlust übernommen.
Abnahme: Steps im Graphen ändern → Konfigurator zeigt den neuen Wert; Preset unter „Edit Presets“ ist unverändert.

**4.3 Abweichungen im Konfigurator.** Markierung abweichender Felder, „Ins Preset übernehmen“, „Zurücksetzen“
(einzeln und alle).
Abnahme: Zurücksetzen stellt Graph und Konfigurator auf das Preset; Übernehmen ändert das Preset und löscht die Markierung.

### Phase 5: Senden über den Graphen

**5.1 Sendepfad.** Wie in 4.4, zunächst hinter einem Schalter in den Einstellungen auch für Standardgraphen, damit
er ohne freie Knoten prüfbar ist. Tests gegen den Fake-Server: Guard blockiert, erzwungene Negative kommen an,
Compiler-Probleme verhindern das Senden.
Abnahme: mit Schalter erzeugt dasselbe Preset dieselben Bilder wie ohne (gleicher Seed).

**5.2 Rezept und Galerie.** Das Rezept hält fest, mit welchem Workflow ein Bild entstand; `docs/GALLERY_FORMAT.md`
und `Gallery.swift` gemeinsam ändern. Offene Detailfrage F1.

**5.3 Fortschritt und Fehler am Knoten.** `RunEvent` → laufender Knoten hervorgehoben, Server-Fehler am Knoten.

### Phase 6: Struktur bearbeiten

**6.1 Verbinden und Trennen.** Von Sockel zu Sockel ziehen, Typprüfung über `NodeGraph.accepts`, Regeln aus 4.5.
Abnahme: falsche Typen rasten nicht ein; Undo stimmt.

**6.2 Hinzufügen und Löschen.** Knotensuche über den Katalog, Löschen mit den Schutzregeln aus 4.5. Ab hier sendet
ein Workflow mit freien Knoten immer über den Graphen, und der Konfigurator zeigt „angepasster Workflow“.
Abnahme: Upscaler hinter dem Decode einhängen, generieren, Bild ist vergrößert.

**6.3 LoRA aus dem Graphen.** `LoraLoader` in die Modellkette hängen → Zusatz-LoRA im Konfigurator; löschen →
dort entfernt; Preset-LoRA löschen → Abweichung.
Abnahme: beide Richtungen deines Ausgangsbeispiels funktionieren.

**6.4 Anker.** Freie Knoten folgen dem Kettenende beim Abgleich.
Tests: freier Knoten am `model`-Anker, dann LoRA hinzu; freier Knoten am `image`-Anker, dann Gesichts-Fix an/aus.

**6.5 Preset-Wechsel.** Gleiche Bauform: abgleichen. Andere Bauform: Dialog „Neu aufbauen (Kopie des alten
Workflows bleibt)“ oder abbrechen.

### Phase 7: Später, jeweils eigener Schritt

Kopieren/Einfügen/Duplizieren · Stummschalten/Bypass · Gruppen · Reroutes · Subgraphs anzeigen und betreten ·
ComfyUI-Dateien importieren (Rollen erkennen, Basis `WorkflowImport`) und exportieren · entkoppelte, völlig freie
Workflows · Live-Vorschau am Knoten · iPad-Touch.

### Phase 8: Workflow-Presets für neue Engines

Ziel: Ein Modell, das Lightbox nicht kennt, läuft ohne neuen Code, sobald es in ComfyUI einen funktionierenden
Workflow dafür gibt. Der Workflow wird zur Vorlage eines Presets; Lightbox setzt Prompt, Seed, Größe und Sampling
ein und sendet ihn über `GraphSend`. Für die bekannten Engines bleibt der abgestimmte Weg über `WorkflowBuilder`.

**8.1 Rollen in fremden Workflows.** Reine Funktion (ComfyKit): In einem UI-Workflow vom Sampler aus die Teile
finden und mit Rollen markieren: Modell-Lader, Text-Encoder, VAE, positiver/negativer Prompt (auch
`ConditioningZeroOut`), leeres Latent, Sampler (KSampler oder `SamplerCustomAdvanced` mit Teilen), Ausgabe,
Guidance/Shift falls vorhanden. Was fehlt, wird benannt („kein Prompt-Knoten gefunden“).
Tests: die vorhandenen Fixtures (Flux, Flux 2, Z-Image, Anima, Krea 2, SDXL) bekommen die erwarteten Rollen;
`ManagedGraph` liest daraus dieselben Werte wie `WorkflowImport`.

**8.2 Vorlage füllen.** Reine Funktion: Vorlage + Anfrage → Dokument. Werte nach Rolle setzen (Prompt aus
`compose()`, Negativ, Seed, Schritte, CFG, Sampler, Scheduler, Größe, Anzahl), LoRAs als Kette zwischen
Modell-Lader und dessen Abnehmern einfügen. Alle anderen Knoten der Vorlage bleiben, wie sie sind.
Tests: gefüllte Vorlage → `ManagedGraph.settings` entspricht der Anfrage; ein zweites Füllen ändert nichts;
Texte gehen durch `GraphSend` (Guard-Tests wie in 5.1).

**8.3 Preset aus einem Workflow.** `GenerationPreset` verweist auf eine Vorlage (gespeichert wie Workflows).
Anlegen aus einer Datei oder aus den im Server gespeicherten Workflows. Der Preset-Editor zeigt „Aus Workflow …“,
die übernommenen Werte und was nicht gefunden wurde. Guides und Gesichts-/Hand-Fix sind bei Vorlagen-Presets aus.

**8.4 Generieren und Graph.** Vorlagen-Presets senden immer über den Graphen; die Node-Ansicht zeigt die gefüllte
Vorlage, Bearbeiten, Workflows und Abweichungen funktionieren wie bei den anderen Presets.
Abnahme: ein Preset aus einem Server-Workflow einer Engine, die Lightbox nicht kennt, erzeugt Bilder.

## 7. Annahmen (bitte widersprechen, wenn falsch)

- **A1** „Standard“ ist kein gespeicherter Workflow, sondern wird immer frisch aus dem Preset abgeleitet. Die
  erste Änderung im Editor legt automatisch einen benannten Workflow an.
- **A2** Unverzichtbare Knoten sind im gekoppelten Workflow nicht löschbar; völlig freie Workflows kommen erst in Phase 7.
- **A3** Ein Checkpoint-Wechsel im Graphen ist nur innerhalb derselben Bauform eine Abweichung. Prompt-Konventionen
  (Dialekt, Stil-Prompt) bleiben die des Presets.
- **A4** Der Standardweg über `WorkflowBuilder` bleibt dauerhaft neben dem Graph-Weg bestehen.
- **A5** Der Seed ist im Graphen änderbar und entspricht dem Seed-Feld.
- **A6** Inpainting und die Bearbeitungsfunktionen des Kompositions-Editors bleiben außerhalb des Node-Editors.

## 8. Offene Detailfragen (werden vor dem jeweiligen Schritt geklärt)

- **F5 (vor 8.3), entschieden:** Ein Workflow einer bekannten Engine ergibt weiterhin ein abgestimmtes Preset; eine
  Option „Workflow als Vorlage behalten“ macht stattdessen ein Vorlagen-Preset.
- **F6 (vor 8.3), entschieden:** Vorlagen kommen aus den im Server gespeicherten Workflows und aus Dateien.

- **F1 (vor 5.2), entschieden:** Wählbar in den Einstellungen. Standard: Das Rezept verweist nur auf den Workflow
  (klein). Eingeschaltet „ganzen Graphen speichern“: Der gesendete Graph wird mit dem Bild gespeichert (exakt
  reproduzierbar, größere Dateien).
- **F2 (vor 3.2), entschieden:** Hat ein Preset Workflows, fragt das Löschen nach. Standard ist „Preset und
  Workflows löschen“; die Alternative „Workflows behalten“ lässt sie ohne Preset stehen.
- **F3 (vor 4.3), entschieden:** Die Workflow-Auswahl gilt pro Preset und übersteht einen Neustart; beim
  Wechsel des Presets erscheint dessen zuletzt gewählter Workflow (oder „Standard“).
- **F4 (vor 6.2), vorläufig entschieden:** Ohne Suchbegriff zeigt die Knotensuche eine kuratierte Auswahl
  (Upscaler, Bildbearbeitung, Speichern); mit Suchbegriff werden alle Knoten des Servers durchsucht.
- **6.1 und 6.2 zusammen:** Verbinden ergibt erst mit eigenen (freien) Knoten etwas, also werden beide Schritte
  gemeinsam gebaut und abgenommen.

## 9. Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Abgleich mit freien Knoten wird unübersichtlich | Anker als einziges Konzept; tabellarische Tests; Anker erst in 6.4, vorher gibt es keine freien Knoten. |
| Beide Sendewege laufen auseinander | Invariante 4.4 als Test über alle Bauformen; 5.1 vergleicht echte Bilder. |
| Guard wird über freie Text-Knoten umgangen | Sendepfad nur über die eine Funktion aus 5.1; Tests in beide Richtungen. |
| Gesten unter macOS (Scrollen, Fokus, Löschtaste) | Eigene Schritte 2.4 und 4.2 mit Rückfallebene. |
| Leistung bei vielen Knoten | Verbindungen und Raster in einem `Canvas`; Messung in 2.4 mit dem größten Standardgraphen. |
| Strict Concurrency | Abbildung und Abgleich sind `Sendable`-Wertfunktionen; nur das Editor-Modell ist `@MainActor @Observable`. |
