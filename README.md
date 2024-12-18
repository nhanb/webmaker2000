Zig 0.13, assuming sdl2 & sqlite3 are installed on system:

```sh
zig build run -fsys=sdl2

# or, to watch:
find src | entr -rc zig build run -fsys=sdl2
```

# What

This is an experiment in [rubbing sqlite][1] on [The Elm Architecture][2], only
going a bit further:

Both data and GUI state are stored in an sqlite3 database, all of which are
queried every frame. All GUI actions trigger changes to the underlying db
instead of mutating any in-memory representation. This sounds expensive, but:

- dvui (the GUI library) only redraws when there is user interaction.
- sqlite has an in-memory page cache out of the box, so _read_ queries do not
  hit the disk every redraw.
- _write_ queries only happen when the user actually changes something, and
  even when they do, sqlite is [fast][3], especially now that SSDs are the norm.

What we gain is a massively simplified unidirectional state management system,
and we get autosave for free on every single action. We also get all of the
benefits of using sqlite as an application file format - off the top of my
head: atomic writes, easy atomic schema changes, powerful data modelling &
querying capabilities.

Remaining puzzles for PoC:

- ~~undo stack~~ Done. Chose emacs-style undo to make it impossible to
  accidentally lose data.
- background processing for tasks that take longer than our per-frame budget:
  + handling mid-operation crashes might be tricky?
  + how would it interact with the undo thing?

[1]: https://www.hytradboi.com/2022/building-data-centric-apps-with-a-reactive-relational-database
[2]: https://guide.elm-lang.org/architecture/
[3]: https://www.sqlite.org/faq.html#q19
