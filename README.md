# Dinner Rush

Co-op restaurant management game. Built with [Rojo](https://github.com/rojo-rbx/rojo) 7.7.0.

## Structure

One Roblox **experience** containing two **places**. Maps are Models inside the
Game place, not separate places - adding a map means adding a model, not
republishing a new place.

```
Dinner Rush                 <- the experience
├── Lobby                   <- start place: zones, party creation, matchmaking
└── Game                    <- match place: the actual restaurant shift
    └── ServerStorage.Maps  <- one Model per restaurant layout
```

| Place | Project file | Source |
| ----- | ------------ | ------ |
| Lobby | `places/lobby.project.json` | `src/lobby` |
| Game  | `places/game.project.json`  | `src/game`  |

`src/shared` syncs into `ReplicatedStorage.Shared` in both places.

## Working on it

Each place syncs separately. Open the place in Studio, then serve its project
file and connect the Rojo plugin:

```bash
rojo serve places/lobby.project.json   # or places/game.project.json
```

Publish with `File -> Publish to Roblox` (Alt+P) from the place you changed -
publishing the Lobby does nothing to the Game place.

## Notes

- Instances that live only in the `.rbxl` (`Teleport_zone`, `MatchMaking_UI`,
  `ReplicatedStorage.Modules.Zone`, `ReplicatedStorage.Remotes`) are not managed
  by Rojo. Renaming or moving one breaks scripts with no compile-time warning.
- Rojo **deletes** anything added in Studio inside a path it manages, so scripts
  belong on disk, not in the Explorer.
- `TeleportService` does not work in Studio playtests. Match teleports have to
  be tested in the published game.
- Set `GAME_PLACE_ID` in `src/lobby/server/QueueServer.server.lua` once the Game
  place exists. Until then the countdown runs but nobody is teleported.