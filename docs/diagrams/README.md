# Documentation diagrams

The project documentation embeds PNG images so diagrams display without
GitHub's Mermaid rich-display JavaScript. Each diagram also has an SVG version
for zooming and an `.mmd` file preserving its original Mermaid source.

The static layouts are defined in `render.py`, which uses Matplotlib and does
not require a browser, model service, or external rendering service. From the
repository root, with Matplotlib installed:

```sh
python3 docs/diagrams/render.py
```

When changing a diagram, update the layout in `render.py` and its corresponding
`.mmd` description, regenerate the PNG/SVG files, and visually inspect the result.
