# Code

Markdown treats code with respect: nothing inside a code span or block is
interpreted, so your snippets come out exactly as written.

## Inline code

Mention a command like `git status` or a value like `nil` right inside a
sentence with backticks.

## Fenced code blocks

Three backticks open a block; a language hint after them labels it:

```swift
struct Note {
    var title: String
    var body: String = ""
}
```

Tildes work as fences too:

~~~python
def greet(name):
    return f"Hello, {name}!"
~~~

And a fence with no language keeps text preformatted, exactly as typed:

```
columns   line up
spaces    are preserved
```

Long lines scroll horizontally instead of wrapping, so code keeps its shape.
