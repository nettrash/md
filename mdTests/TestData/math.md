# Math

Inline math: the identity $a^2 + b^2 = c^2$ and Euler's \(e^{i\pi} + 1 = 0\).
Markdown stays literal inside math: $a*b*c$ is a product and $x_1 + x_2$
carries subscripts.

The currency guard keeps prose intact: it costs $5 and $10 today, and $99.99
is a price. A code span keeps its dollars too: `$x$`.

Display math with double dollars:

$$\int_0^1 x^2\,dx = \frac{1}{3}$$

…and with bracket delimiters:

\[ \sum_{k=1}^{n} k = \frac{n(n+1)}{2} \]

A fenced block tagged `math`:

```math
\begin{aligned}
  (a + b)^2 &= a^2 + 2ab + b^2
\end{aligned}
```

Inline math flows through table cells, list items and quotes:

| Symbol | Meaning                            |
| ------ | ---------------------------------- |
| $\pi$  | ratio of circumference to diameter |

- The golden ratio $\varphi = \frac{1 + \sqrt5}{2}$.

> A right triangle satisfies $a^2 + b^2 = c^2$.
