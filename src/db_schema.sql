begin;

pragma foreign_keys = on;

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

-- TODO remove seed data
insert into post (title, content) values
    ('First!', 'This is my first post.'),
    ('Second post', 'Let''s keep this going.
Shall we?')
;

commit;
