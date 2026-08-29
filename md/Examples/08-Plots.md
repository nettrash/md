# Plots

Write a formula in a fence and md draws it. Unlike the diagrams next
door, a plot needs no engine: the app works out the curve and writes the
picture itself, so nothing is bundled for it, nothing is downloaded, and
a document full of plots loads no more than a document full of prose.

## A function

A block tagged `plot` draws its lines as functions of `x`:

```plot
sin(x)
```

That is the whole of it. The window defaults to `x` from −10 to 10, and
a vertical range chosen to fit whatever the curve does.

## Choosing the window

`x:` and `y:` set the ranges. `y:` may be left out, or written `auto`,
to let the figure fit itself around the values:

```plot
x: 0..6.283185
y: -1.5..1.5
sin(x)
cos(x)
```

Two lines in the block, two curves in the figure, each in its own
colour.

## Naming the curves

Put a name in front of a formula and it appears in a legend. A title
and axis labels are three more lines:

```plot
x: -10..10
y: -1.2..1.2
title: A damped oscillation
xlabel: time
ylabel: amplitude
envelope = exp(-abs(x)/5)
signal = sin(x) * exp(-abs(x)/5)
```

`legend`, `grid` and `axes` each take `on` or `off` if you would rather
not have them, and `width`, `height` and `samples` take numbers.

## Curves that are not functions

A curve can be traced by a parameter instead, with a formula for each
coordinate — which is how you draw something a function cannot, like a
closed loop:

```plot
x: -1.2..1.2
y: -1.2..1.2
title: A Lissajous figure
(sin(3*t), cos(5*t)) for t in 0..6.283185
```

And a series of plain points is written out, to plot numbers you already
have rather than a formula:

```plot
x: 0..8
y: 0..1200
title: Words per day
points: 1,420 2,980 3,610 4,1150 5,300 6,760 7,890
```

## What you can write

The usual arithmetic — `+ - * / %` and `^` for powers — with
comparisons (`< <= > >= == !=`) that come out as 1 or 0, which is a
handy way to draw half of something:

```plot
x: -6..6
y: -1..3
(x > 0) * sqrt(x)
```

The functions are `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `sinh`,
`cosh`, `tanh`, `asinh`, `acosh`, `atanh`, `sqrt`, `cbrt`, `abs`, `exp`,
`exp2`, `ln`, `log2`, `log10`, `floor`, `ceil`, `round`, `atan2`, `pow`
and `hypot`, and `pi` and `e` are there to be used.

If a formula cannot be read, the block says so in one line and keeps
your text visible underneath, so nothing you wrote is ever lost to a
typo.

## Where a plot ends up

A plot is a drawing, not a picture of one, so it stays sharp wherever it
goes: the preview, print, an exported PDF, an exported HTML page, and an
EPUB — where it is the one kind of rich block that stays a vector. Any
single figure can also be saved on its own through **Export Diagram as
SVG**, beside the Mermaid, Graphviz and PlantUML drawings.

A LaTeX export is the exception: it keeps the fence as you wrote it,
under a comment, the same way it treats the other diagram languages.

Because a plot is just a formula in text, it costs a line to change and
a line to review — and it is right every time the numbers move.
