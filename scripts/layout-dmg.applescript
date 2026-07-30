on run arguments
    if (count of arguments) is not 1 then
        error "usage: layout-dmg.applescript <volume-name>"
    end if

    set volumeName to item 1 of arguments

    tell application "Finder"
        set targetDisk to disk (volumeName as text)
        tell targetDisk
            open

            tell container window
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                set pathbar visible to false
                set sidebar width to 0
                -- The 453-point outer height leaves a 420-point content area
                -- below Finder's 33-point title bar on supported macOS.
                set bounds to {120, 120, 780, 573}
            end tell

            set viewOptions to icon view options of container window
            tell viewOptions
                set arrangement to not arranged
                set icon size to 96
                set text size to 13
                set shows item info to false
                set shows icon preview to true
            end tell
            set background picture of viewOptions to file ".background:Caffeine.png"

            set position of item "Caffeine.app" of container window to {205, 224}
            set position of item "Applications" of container window to {455, 224}

            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
