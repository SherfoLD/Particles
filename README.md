# Particles

![Colorful balls falling across the desktop in Waterfall mode](Docs/Media/waterfall.gif)

Your Mac desktop has gravity now.

Particles is a macOS menu bar playground that drops colorful balls onto your desktop. They bounce off files, folders, widgets, the Dock, open windows, screen edges, and each other. Leave them alone and they make little piles. Move a window through a pile and see what happens.

## Play

1. Build and launch the app using the [developer guide](Docs/Development.md#build-and-run). It supports macOS 14 and later.
2. Find the small circle in your menu bar. Particles has no Dock icon.
3. Choose **Spawn balls** for a waterfall, or select **Cannon** and choose **Spawn cannon**.

The waterfall starts with 10,000 balls spread across your displays.

In cannon mode, each display gets a cannon: drag its wheel to move it, drag its barrel or scroll over it to aim, and watch it fire.

![A desktop cannon firing colorful balls in Cannon mode](Docs/Media/canon.gif)

Choose **Remove balls** or **Remove cannon** for a clean slate. Switching modes clears the current simulation; choose **Spawn balls** or **Spawn cannon** to start the new one.

| Menu control | What it does |
| --- | --- |
| **Balls** | Choose how many balls the next waterfall drops. Stop the waterfall to change it. |
| **Fire rate** | In cannon mode, choose how quickly the cannons shoot. Changes apply immediately. |
| **Ball size** | Choose Small, Medium, or Large before spawning. Larger balls have lower count limits. |
| **Ball speed** | Change the speed limit while the balls are moving. |
| **Cursor collisions** | Turn your cursor into an invisible brush and stir the balls as you move it. |

The overlay lets clicks pass through to your desktop and other apps; only the cannon catches mouse input. Balls rest on window tops, tumble when windows move, and pause with their display when you switch Spaces or your Mac sleeps. If a window crushes a pile into a space too small for it, some balls disappear. Spawn a fresh batch to bring them back.

On first launch, macOS may ask for **Desktop Folder** and **Finder Automation** access so balls can recognize desktop icons. If you decline, the app still runs, but files and folders will not stop the balls. You can enable them later under **System Settings → Privacy & Security → Files and Folders** and **Automation**, then relaunch. Particles does not need Accessibility or screen recording access.

## Developing

Build commands, project structure, sandbox scenarios, and performance checks are in [Docs/Development.md](Docs/Development.md).
