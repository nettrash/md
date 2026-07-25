# Tables

md renders GitHub-style tables: pipes divide the columns, and a row of
dashes separates the header from the body.

| Day       | Plan                | Done    |
| --------- | ------------------- | ------- |
| Monday    | Outline the article | Yes     |
| Tuesday   | First draft         | Yes     |
| Wednesday | Edit and polish     | Not yet |

## Column alignment

Colons in the divider row set the alignment — left, center, or right:

| Item     | Quantity |  Price |
| :------- | :------: | -----: |
| Notebook |    2     |   9.90 |
| Pen      |    12    |   1.25 |
| Desk     |    1     | 240.00 |

Right-aligned columns keep numbers tidy.

## Formatting inside cells

Cells can hold inline formatting, links, and code:

| Write this  | Get this                    |
| ----------- | --------------------------- |
| `**bold**`  | **bold**                    |
| `*italic*`  | *italic*                    |
| `[link](…)` | [link](https://nettrash.me) |

Wide tables scroll sideways in Preview rather than squeezing the text.

## Straight from a spreadsheet

Pipes are fine for a table you write by hand, but figures usually arrive
from somewhere else. Paste them as they come into a block tagged `csv` —
or `tsv`, for the tab-separated text a spreadsheet puts on the clipboard —
and md draws the table for you:

```csv
Item,"Size, packed",Units,Price
Notebook,21 × 30 cm,120,9.90
Pen,14 cm,640,1.25
Pipe,"5"" copper",18,3.40
```

The first row is the header. A field wrapped in quotes may hold a comma —
"Size, packed" above — and a doubled quote inside such a field is one
literal quote, which is how the 5" pipe keeps its inch mark. Columns that
hold nothing but numbers are lined up on the right, so the decimal points
sit under one another.

The block stays the data you pasted, so when next month's figures arrive
you replace the whole thing rather than editing it cell by cell.
