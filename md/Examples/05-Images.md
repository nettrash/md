# Images

An image is a link with a `!` in front: `![alt text](url)`. Images render
at their original size, capped to the page width.

## From the web

Remote images load right into the preview:

![nettrash.me favicon](https://nettrash.me/favicon.ico "Loaded from the web")

A title in quotes, like the one above, adds a caption on hover.

## Linked images

Wrap an image in a link and it becomes a clickable picture:

[![badge](https://nettrash.me/favicon.ico)](https://nettrash.me)

Choosing it opens nettrash.me.

## Embedded images

Images can travel *inside* the document as a `data:` URI — no network
needed, so this little red dot renders even offline:

![A tiny embedded red dot](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAJElEQVR4AWP4//8/AwwzMjKCMTKfIAsZM6DxCbKQMQMan7AtAJqTFPtCK1UyAAAAAElFTkSuQmCC)

Embedded images are handy for logos and small marks that a document
should carry with it wherever it goes.
