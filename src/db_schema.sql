pragma foreign_keys = on;
pragma user_version = 1;

create table post (
    id integer primary key,
    title text,
    content text
);

create table gui_scene (
    id integer primary key check (id = 0) default 0,
    current_scene integer default 0
);
insert into gui_scene (id) values (0);

create table gui_scene_editing (
    id integer primary key check (id = 0) default 0,
    post_id integer default null,
    foreign key (post_id) references post (id) on delete set null
);
insert into gui_scene_editing (id) values (0);

create table gui_modal (
    id integer primary key check (id = 1),
    kind integer not null
);

create table history_undo (
    id integer primary key autoincrement,
    statement text not null check (statement <> ''),
    undone boolean not null default false
);
create table history_barrier_undo (
    id integer primary key autoincrement,
    history_id integer unique not null,
    description text not null check (description <> ''),
    undone boolean not null default false,

    foreign key (history_id) references history_undo (id) on delete cascade
);

-- A redo is either created or deleted, never undone.
-- The `undone` column is only there to stay compatible with the undo tables so
-- we can use the same code on both of them.
create table history_redo (
    id integer primary key autoincrement,
    statement text not null check (statement <> ''),
    undone boolean not null default false check (undone = false)
);
create table history_barrier_redo (
    id integer primary key autoincrement,
    history_id integer unique not null,
    description text not null check (description <> ''),
    undone boolean not null default false check (undone = false),

    foreign key (history_id) references history_redo (id) on delete cascade
);

-- TODO remove seed data
insert into post (title, content) values
    ('First!', 'This is my first post.'),
    ('Second post', 'Let''s keep this going.
Shall we?')
;
