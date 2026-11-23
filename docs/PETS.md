# Desktop pets

A pet is one bot's own picture, sitting on the Mac's desktop with nothing around it. It is the whole
window: no title bar, no panel, no background — the bot's face on your wallpaper, doing small things
while you work, and answering a question when you click it.

Pets are macOS only, off by default, and switched on one bot at a time. A phone has no desktop to sit
on; there the bot's picture in the bot list is the same idea, already done.

## What a pet is

One pet, one window, one bot. The window is the icon's own 96 pt square plus a clear 12 pt margin the
picture never draws into, and everything else about it is invisible: no frame, no coloured background,
no shadow rectangle. What you see is the bot's face, with the desktop showing through everywhere the
picture is transparent.

The clear parts are not clickable. A click on a corner of the pet's square goes to whatever is behind
it — the desktop, another app's window — the way a click on empty space should. The click that reaches
the pet is the one that lands on the picture. That is the difference between a pet on a desktop and a
widget parked on it.

## Putting one on the desktop

Open the bot's own settings and find **Desktop pet**, then turn the switch on. The switch is labelled
with the bot's name — *Show* that bot *on the desktop* — and the pet appears straight away, at the
centre of the screen you are on. **Bring it here** puts it back there
later if you have dragged it somewhere and lost it.

- **Per bot.** Each bot has its own switch, so the desk can carry one pet or five.
- **Off by default.** Nothing appears until you turn it on for that bot.
- **Per Mac.** Which pets are on this desk is a property of this desk. It is stored in the app's own
  settings, not on the host, so a second Mac starts with no pets and nothing follows you between them.
- **They come back at launch.** Quitting Hermey takes the pets away without touching the switches;
  the next launch puts them back where they were.

## What it does while you leave it alone

The pet is not a still image. On its own clock it does one of four things — a small bob, a tilt, a
short hop, or a wander of a few points — every 8 to 30 seconds, chosen at random so two pets on one
desk never move in step. It blinks every 3 to 9 seconds, and the whole face drifts a few points left
and right every couple of seconds, which is what makes a still picture read as looking around.

Nothing is drawn over the art: the movement is all transform on the bot's own picture, so a bot with a
custom face needs no second animation asset.

With **Reduce Motion** on in macOS the pet calms down rather than stopping: the bob is halved, the
hops, tilts and wander are dropped, the drifting stops, and the blink becomes a gentler squash.

## Clicking it: the balloon

Click the pet and a frosted speech balloon opens beside it — above and to one side, never over the
icon, so the pet stays visible while you type. The tail points at the pet, and the balloon picks a
seat that fits the display: above-right by default, above-left when the right edge would run off the
screen, centred above, below when there is no room above, and beside it on a short display.

- **Type, then Return.** The question goes to that bot. One question at a time: the field is disabled
  while a turn is in flight.
- **Thinking.** The balloon says **Thinking…** until the answer arrives.
- **The answer grows to a cap, then scrolls.** The balloon is sized to its content up to a ceiling;
  a long reply scrolls inside it instead of covering the screen. **Copy** puts the text on the
  clipboard (and the button says **Copied**).
- **Dismissing is not resetting.** Escape, or a click anywhere else, closes the balloon. Click the pet
  again and the last exchange is still there. **New** is the explicit reset: it clears the balloon and
  anything in flight and leaves an empty field ready.
- **Two minutes is the timeout.** A pet's question is a turn of its own addressed to the bot, marked
  as coming from the desktop pet (`POST /v1/bots/{profile}/ask` with `from: desktop-pet`), so it does
  not have to go through the conversation you have open in the window. If the host has not answered
  in two minutes the balloon says **Sent — it hasn't answered yet.** with **Retry**.

## The badge, and the hop you did not see

The pet shows the same unread count the bot list does — the app's own number, not a second tally.

- **A reply lands while Hermey is minimised or hidden and the pet hops** and puts a badge on the
  icon's top-right corner: a dot for one turn waiting, the number for more, `9+` past nine. The hop is
  the pet telling you something arrived while you were not looking. If you can see the window, nothing
  hops — you are already reading it.
- **The badge is the count, shown.** Nothing pops up by itself; the balloon waits for your click.
- **Clicking the pet opens the balloon and clears the badge**, because reading the answer is reading
  the bot — the bot list's dot goes at the same time.

## Moving it, closing it, and where it lives

- **Drag it anywhere.** The position is remembered per bot and per screen, so a pet can live on the
  second display and stay there. Unplug the display or change the resolution and the pet is moved back
  onto a screen you can see, at the next launch and when the screen setup changes.
- **Right-click → Close pet.** The window closes and the bot's **Desktop pet** switch goes off with it,
  so the settings toggle is the way back. A pet closed this way comes back centred when you switch it
  on again.
- **It floats.** The pet is above normal windows and follows you across Spaces; over a full-screen app
  macOS may hide it, which is the platform's call rather than the app's.

## Troubleshooting

| What you see | What it means |
|---|---|
| No pet after switching it on | Check you are looking at the right screen — press **Bring it here** in that bot's settings. macOS only: the pet does not exist on iOS. |
| The pet is not where you left it | The display it was on is gone or its resolution changed. It is moved onto a visible screen; drag it where you want it and it is remembered again. |
| A click beside the pet does nothing | By design: only the picture takes clicks, and the clear corners of its square pass the click to the desktop. Click the face. |
| **Can't reach the host right now.** | The app cannot reach `hermeyd`. Check the Mac is still paired and the host is up — the pet itself keeps drawing. |
| **Sent — it hasn't answered yet.** | The question reached the bot and it had not answered by the timeout. **Retry** re-sends the same question. |
| The pet answers but you cannot find the answer later | The pet keeps its last exchange only while it is on screen, and nothing is written to disk. A pet's transcript is not a document. |
| Two pets, one desk | Fine, and supported: each has its own window, position and question. |

## The design it was built from

[`docs/DESKTOP-PETS.md`](DESKTOP-PETS.md) is the design record: the window behaviour, the decisions
worth stating, the risks, and the corrections the build forced. It is written for whoever changes the
feature, not for whoever uses it.
