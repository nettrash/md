# Math

md typesets LaTeX math with a bundled KaTeX engine — entirely on your
device, no network needed. Formulas render in Preview; Edit shows the source.

## Inline math

Put a formula between single dollars and it flows with the text: the
Pythagorean theorem $a^2 + b^2 = c^2$, or Euler's identity
\(e^{i\pi} + 1 = 0\) using the parenthesis form.

Everyday prices stay prose — it costs $5 today and $10 tomorrow — md only
typesets real formulas.

## Display math

Double dollars center a formula on its own line:

$$\int_0^1 x^2\,dx = \frac{1}{3}$$

Bracket delimiters do the same:

\[ \sum_{k=1}^{n} k = \frac{n(n+1)}{2} \]

## Multi-line math

A fenced block tagged `math` is perfect for aligned derivations:

```math
\begin{aligned}
  (a + b)^2 &= a^2 + 2ab + b^2 \\
  (a - b)^2 &= a^2 - 2ab + b^2
\end{aligned}
```

Math flows through tables, lists, and quotes too:

> The golden ratio is $\varphi = \frac{1 + \sqrt{5}}{2} \approx 1.618$.
