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
    statement text not null check (statement <> '')
);
create table history_undo_barrier (
    id integer primary key autoincrement,
    history_undo_id integer unique not null,
    description text not null check (description <> ''),
    foreign key (history_undo_id) references history_undo (id) on delete cascade
);

-- TODO remove seed data
insert into post (title, content) values
    ('First!', 'This is my first post.'),
    ('Second post', 'Let''s keep this going.
Shall we?')
;
