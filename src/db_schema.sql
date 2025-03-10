pragma foreign_keys = on;
pragma user_version = 1;

create table post (
    id integer primary key,
    slug text not null default '',
    title text not null default '',
    content text not null default ''
);

create table attachment (
    id integer primary key,
    post_id integer not null,
    name text not null,
    data blob not null,
    foreign key (post_id) references post (id) on delete cascade,
    unique(post_id, name)
);

create table gui_attachment_selected (
    id integer primary key,
    foreign key (id) references attachment (id) on delete cascade
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

create view gui_current_post_err as
select
    p.id as post_id,
    p.title == '' as empty_title,
    p.slug == '' as empty_slug,
    p.content == '' as empty_content,
    exists(select 1 from post p1 where p1.slug = p.slug and p1.id <> p.id) as duplicate_slug
from post p
inner join gui_scene_editing e on e.post_id = p.id;

create table gui_modal (
    id integer primary key check (id = 1),
    kind integer not null
);

create table history_undo (
    id integer primary key autoincrement,
    statement text not null check (statement <> ''),
    barrier_id integer,

    foreign key (barrier_id) references history_barrier_undo (id) on delete cascade
);
create table history_barrier_undo (
    id integer primary key autoincrement,
    action integer not null,
    undone boolean not null default false,
    created_at text not null default (datetime('now'))
);

create table history_redo (
    id integer primary key autoincrement,
    statement text not null check (statement <> ''),
    barrier_id integer,
    foreign key (barrier_id) references history_barrier_redo (id) on delete cascade
);
-- A redo is either created or deleted, never undone.
-- The `undone` column is only there to stay compatible with the undo tables so
-- we can use the same code on both of them.
create table history_barrier_redo (
    id integer primary key autoincrement,
    action integer not null,
    undone boolean not null default false check (undone = false),
    created_at text not null default (datetime('now'))
);

-- TODO remove seed data
insert into post (slug, title, content) values
    ('first', 'First!', 'This is my first post.'),
    ('second', 'Second post', 'Hello I''m written in [djot](https://djot.net/).

How''s your _day_ going?')
;

create table history_enable_triggers (
    id integer primary key check (id=0),
    undo boolean not null default true,
    redo boolean not null default false
);
insert into history_enable_triggers(id) values (0);

create table gui_status_text (
    id integer primary key check (id = 0) default 0,
    status_text text default '',
    expires_at text default (datetime('now'))
);
insert into gui_status_text (id) values (0);
