# Diagrams

Describe a diagram in text and md draws it — the Mermaid and PlantUML
engines are bundled with the app and run entirely offline.

## Mermaid

A fenced block tagged `mermaid` becomes a diagram. A flowchart:

```mermaid
flowchart TD
  A[Idea] --> B{Worth writing down?}
  B -->|Yes| C[Open md]
  B -->|No| D[Let it go]
  C --> E[Share it]
```

A sequence diagram:

```mermaid
sequenceDiagram
  participant Y as You
  participant M as md
  Y->>M: Type Markdown
  M-->>Y: Rendered preview
```

Mermaid also draws pie charts, state diagrams, Gantt charts, and more.

## PlantUML

A block tagged `plantuml` (or `puml`) is rendered by PlantUML — wrap the
source in `@startuml` … `@enduml`:

```plantuml
@startuml
Author -> Editor : write chapter
Editor --> Author : live preview
Author -> Exporter : share as PDF
@enduml
```

Because diagrams are plain text, they copy, edit, and version like prose.
