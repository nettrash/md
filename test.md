# test.md — Markdown feature reference

A single document exercising every Markdown feature the **md** renderer
supports, plus the common syntax in general. Open it in the app and flip
between **Edit**, **Split** and **Preview** to eyeball the renderer.

This first paragraph is plain prose. It wraps across multiple source lines
but renders as one paragraph, because a paragraph is only broken by a
blank line. Soft line breaks inside a paragraph are collapsed to spaces.

A second paragraph follows the blank line above. To force a hard line
break, end a line with two trailing spaces —  
this text is on a new line within the same paragraph.

---

## 1. Headings

# Heading level 1 (ATX)
## Heading level 2
### Heading level 3
#### Heading level 4
##### Heading level 5
###### Heading level 6

### A heading with `code`, *italics* and **bold** inline

C# and F# headings (the `#` is part of the text, not a 7th level)

Setext heading level 1
======================

Setext heading level 2
----------------------

---

## 2. Inline formatting

- **Bold** with double asterisks and __double underscores__
- *Italic* with single asterisks and _single underscores_
- ***Bold and italic together***
- `inline code` with backticks
- ~~Strikethrough~~ text
- A [link to nettrash.me](https://nettrash.me)
- A [link with a title](https://nettrash.me "Hover title")
- An autolink: <https://nettrash.me>
- An email autolink: <nettrash@nettrash.me>
- Escaped characters: \*not italic\*, \`not code\`, \# not a heading
- Mixed: **bold with `code` and _italic_ inside**

---

## 3. Blockquotes

> A simple block quote.
>
> Spanning multiple paragraphs within the same quote.

> Quotes can contain other elements:
>
> - a list item
> - another item
>
> ```
> and even a code block
> ```

> Level one
>> Level two (nested)
>>> Level three (nested deeper)

---

## 4. Lists

### Unordered

- First item
- Second item
- Third item with a longer line of text that wraps onto more than one
  visual line to check continuation alignment
* Asterisk bullets work too
+ Plus bullets work too

### Ordered

1. First
2. Second
3. Third
4. Numbers need not be sequential in source
1. (this renders as item 5)

### Nested (mixed)

1. Top level ordered
   - Nested unordered
   - Another nested item
     1. Deeper ordered
     2. Deeper ordered two
2. Back to top level
   - With a nested bullet

### Task lists

- [ ] Unchecked task
- [x] Checked task
- [ ] Task with **bold** and `code`
  - [x] Nested completed subtask
  - [ ] Nested pending subtask

---

## 5. Code

Inline `let x = 42` in a sentence.

A fenced code block with a language hint (triple backticks):

```swift
struct MarkdownDocument: FileDocument {
    var text: String
    static var readableContentTypes: [UTType] { [.markdown, .plainText] }
}
```

A fenced code block using tildes:

~~~json
{
  "name": "md",
  "platforms": ["iOS", "iPadOS"],
  "dependencies": []
}
~~~

A fenced block with no language:

```
plain preformatted text
    indentation is preserved
1 + 1 = 2
```

A code block with a very long line to check horizontal scrolling: `the quick brown fox jumps over the lazy dog and keeps on running far past the right edge of the page`:

```
this_is_a_single_unbroken_line_that_should_scroll_horizontally_rather_than_wrap_in_the_rendered_code_block_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

---

## 6. Tables

A GitHub-style table with default alignment:

| Feature      | Supported | Notes                     |
| ------------ | --------- | ------------------------- |
| Headings     | Yes       | ATX and setext            |
| Tables       | Yes       | With column alignment     |
| Footnotes    | Maybe     | Depends on the renderer   |

Column alignment (left, center, right):

| Left aligned | Center aligned | Right aligned |
| :----------- | :------------: | ------------: |
| a            |       b        |             c |
| longer text  |    centered    |      1,000,000 |
| x            |       y        |             z |

A table with inline formatting in cells:

| Syntax       | Renders as      |
| ------------ | --------------- |
| `**bold**`   | **bold**        |
| `*italic*`   | *italic*        |
| `~~strike~~` | ~~strike~~      |
| `[link](/)`  | [link](https://nettrash.me) |

---

## 7. Thematic breaks

Three or more of `-`, `*` or `_` on their own line:

---

***

___

---

## 8. Images

Inline image (may not render if the renderer is text-only):

![Alt text for an image](https://nettrash.me/favicon.ico "Optional title")

A linked image:

[![Alt text](https://nettrash.me/favicon.ico)](https://nettrash.me)

---

## 9. Edge cases & mixed content

A paragraph immediately followed by a list (no blank line between, which
some parsers treat as a lazy continuation):
- item one
- item two

A list item containing a fenced code block:

1. Run the build:
   ```bash
   xcodebuild build -project md.xcodeproj -scheme md \
     -destination 'generic/platform=iOS'
   ```
2. Open a `.md` file and start editing.

A blockquote that contains a table:

> | Key | Value |
> | --- | ----- |
> | a   | 1     |
> | b   | 2     |

Unicode and emoji: café, naïve, Москва, 日本語, 😀 📝 ✅.

The end. If everything above renders sensibly in **Preview**, the parser
and renderer are healthy.
