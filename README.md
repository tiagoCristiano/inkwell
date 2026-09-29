# Inkwell for KOReader

A KOReader plugin that works as a **client** for a social network for readers: feed, posts,
reviews, highlighted quotes, comments, likes, followers and communities.

## It's just a client

The plugin has no built-in server. It points to the official Inkwell server by default,
but the user can switch to any other. All it does is:

- send HTTP/JSON requests to the API you configure;
- display what the API returns;
- display the API's error messages exactly as it sends them.

Any server that implements the contract below works with this plugin.

## Installation

1. Copy the `inkwell.koplugin/` folder to `koreader/plugins/` on the device.
2. Restart KOReader.
3. Open **Inkwell** from the tool menu.

## Configuring the API

By default the plugin uses the official server, `https://inkwell-server-0n1p.onrender.com`.

To use another API, change the **Server** field on the login screen to its base URL, for example
`https://api.example.com` (no trailing slash). The plugin saves this value as
`inkwell_server_url` in KOReader's settings and uses that URL for every request.
If you clear the field, the plugin goes back to the official server.

To switch servers, log out (**Menu → Log out**) and enter another URL on the login screen. The
session token belongs to the server that issued it, so switching servers requires a new login.

The **Quick login** buttons use test accounts and only work on a development server that has
those accounts created (see `mock-server/prisma/seed.js`).

## API contract

All routes, except `/auth` and image URLs, receive `Authorization: Bearer <token>`.
Request and response bodies are JSON.

### Responses and errors

| Status        | What the client does                                  |
| ------------- | ----------------------------------------------------- |
| `200` / `201` | uses the JSON                                         |
| `204`         | treats it as success with no body                     |
| `401`         | clears the session and asks for login again           |
| `403`         | shows the response's `error` (or "permission denied") |
| anything else | shows `{ "error": "message" }`, if present            |

The plugin shows the `error` text as-is, so the server writes the final user-facing message

### Authentication

| Method | Route            | Body                  | Response                                         |
| ------ | ---------------- | --------------------- | ------------------------------------------------ |
| POST   | `/auth/login`    | `{ email, password }` | `200 { token, username, can_create_moderator? }` |
| POST   | `/auth/register` | `{ email, password }` | `201 { token, username, can_create_moderator? }` |

### UI flags

The client has no permission logic. The server
decides everything and sends the result as flags; the client only shows a button when its flag
is `true`. Hiding a button is cosmetic, so every route must still check authorization on the
server.

| Where              | Flag                   | Button                      |
| ------------------ | ---------------------- | --------------------------- |
| login              | `can_create_moderator` | Menu → Create moderator     |
| `topic` (full)     | `can_delete`           | Delete post                 |
| `topic.comments[]` | `can_delete`           | Delete comment              |
| `community`        | `can_edit_cover`       | Choose/Change cover         |
| `community`        | `can_leave`            | Leave community             |
| `community`        | `can_post`             | New post                    |
| `profile`          | `badge` (text)         | badge next to the @username |

### Routes

| Method             | Route                                               | Purpose                                                      |
| ------------------ | --------------------------------------------------- | ------------------------------------------------------------ |
| GET                | `/topics?offset&limit&feed=following\|reviews\|all` | feed (`{ topics, has_more, total, unread_notifications }`)   |
| GET                | `/topics/search?q=`                                 | search (`@author`, `#tag` or text)                           |
| GET / PUT / DELETE | `/topics/:id`                                       | view, edit, delete post                                      |
| POST               | `/topics`                                           | new post / review / quote / community post                   |
| POST / DELETE      | `/topics/:id/like`                                  | like / unlike                                                |
| POST               | `/topics/:id/comments`                              | comment (`parent_id` replies to a comment)                   |
| DELETE             | `/topics/:id/comments/:cid`                         | delete comment                                               |
| POST / DELETE      | `/comments/:id/like`                                | like / unlike comment                                        |
| GET / POST         | `/communities`                                      | list / create community                                      |
| GET                | `/communities/:id`                                  | community with its posts                                     |
| POST / DELETE      | `/communities/:id/members`                          | join / leave                                                 |
| PUT                | `/communities/:id/cover`                            | cover (`{ data: base64, content_type }`)                     |
| GET / PUT          | `/me/profile`                                       | my profile                                                   |
| PUT                | `/me/avatar`                                        | avatar (`{ data: base64, content_type }` → `{ avatar_url }`) |
| GET                | `/me/posts`                                         | my posts                                                     |
| GET                | `/me/notifications` · POST `/me/notifications/read` | activity                                                     |
| PUT                | `/me/reading`                                       | progress of the open book                                    |
| GET                | `/users/:username`                                  | public profile                                               |
| POST / DELETE      | `/users/:username/follow`                           | follow / unfollow                                            |
| GET                | `/users/:username/followers\|following`             | people lists                                                 |
| GET                | `/books?title=`                                     | book page                                                    |
| GET                | `/trending`                                         | trending tags and books                                      |
| POST               | `/admin/users`                                      | create moderator (only called if `can_create_moderator`)     |

Image URLs (`avatar_url`, `cover_url`, `book_cover_url`) must be absolute and public,
because the plugin downloads them without a token.
