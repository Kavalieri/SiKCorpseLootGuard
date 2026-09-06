# Contributing

Thank you for helping improve SiK Corpse Loot Guard. Please open an issue before writing
code. Unsolicited code is not accepted by default.

A useful bug report includes the visible version, game mode, exact steps,
expected and actual results, relevant mods and `console.txt` only when it is
pertinent and contains no credentials or private data. Integration proposals
must describe the public, data-driven contract they need and must not depend on
private implementation details.

While SiK prepares an official fix, you may propose an original, minimal,
non-commercial temporary patch as a diff or pull request in this official
repository. State the affected version, reproduction steps and scope, and
confirm that you authored the contribution. This does not authorise complete
files, publishable forks, Workshop reuploads, SiK branding or extra content.
The permission ends when SiK publishes a replacement, withdraws the patch for
security or compatibility, or announces another status.

By submitting a pull request, you grant SiK a non-exclusive, worldwide,
royalty-free, sublicensable and irrevocable licence to integrate, modify and
redistribute the contribution in SiK products. You retain authorship of your
original contribution.

Before a push, run `pwsh -NoProfile -File tools/check-public-tree.ps1`. Enable
the repository hook once with `git config core.hooksPath .githooks`; CI runs
the same indexed-tree gate for every push and pull request.

## Español

Gracias por ayudar a mejorar SiK Corpse Loot Guard. Abre primero una incidencia; no se
acepta código no solicitado por defecto.

Incluye versión visible, modo de juego, pasos exactos, resultado esperado y
real, mods relevantes y `console.txt` solo cuando sea pertinente y no contenga
credenciales ni datos privados. Las integraciones deben explicar el contrato
público y data-driven que necesitan, sin depender de detalles internos.

Mientras SiK prepara el arreglo oficial puedes proponer un parche temporal
propio, mínimo y no comercial como diff o pull request. Indica versión, pasos,
alcance y autoría. No autoriza archivos completos, forks publicables, reuploads
de Workshop, marca SiK ni contenido adicional. La autorización termina al
publicarse el reemplazo oficial, retirarse por seguridad/compatibilidad o
comunicarse otro estado. Todo PR concede a SiK la licencia de contribución
indicada arriba; conservas la autoría de tu aportación original.
