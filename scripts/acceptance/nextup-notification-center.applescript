on failClosed(messageText)
    error messageText number 2
end failClosed

on directChildren(elementRef)
    tell application "System Events"
        try
            return UI elements of elementRef
        on error
            return {}
        end try
    end tell
end directChildren

on descendants(elementRef)
    set collected to {}
    set pending to my directChildren(elementRef)
    repeat while (count pending) > 0
        set currentElement to item 1 of pending
        if (count pending) = 1 then
            set pending to {}
        else
            set pending to items 2 thru -1 of pending
        end if
        set end of collected to currentElement
        set pending to pending & my directChildren(currentElement)
    end repeat
    return collected
end descendants

on roleOf(elementRef)
    tell application "System Events"
        try
            return value of attribute "AXRole" of elementRef
        on error
            return ""
        end try
    end tell
end roleOf

on attributeText(elementRef, attributeName)
    tell application "System Events"
        try
            set rawValue to value of attribute attributeName of elementRef
            if rawValue is missing value then return ""
            return rawValue as text
        on error
            return ""
        end try
    end tell
end attributeText

on exactStaticTextCount(elementRef, exactTitle)
    set matches to 0
    repeat with candidate in my descendants(elementRef)
        if my roleOf(candidate) is "AXStaticText" then
            if my attributeText(candidate, "AXValue") is exactTitle then set matches to matches + 1
        end if
    end repeat
    return matches
end exactStaticTextCount

on childGroupContainsTitle(elementRef, exactTitle)
    repeat with childElement in my directChildren(elementRef)
        if my roleOf(childElement) is "AXGroup" then
            if my exactStaticTextCount(childElement, exactTitle) is 1 then return true
        end if
    end repeat
    return false
end childGroupContainsTitle

on notificationGroups(notificationProcess, exactTitle)
    set matches to {}
    repeat with candidate in my allDescendants(notificationProcess)
        if my roleOf(candidate) is "AXStaticText" then
            if my attributeText(candidate, "AXValue") is exactTitle then
                set ancestor to my parentOf(candidate)
                repeat while ancestor is not missing value
                    if my roleOf(ancestor) is "AXGroup" then
                        set end of matches to ancestor
                        exit repeat
                    end if
                    set ancestor to my parentOf(ancestor)
                end repeat
            end if
        end if
    end repeat
    return matches
end notificationGroups

on allDescendants(elementRef)
    tell application "System Events"
        try
            return entire contents of elementRef
        on error
            return {}
        end try
    end tell
end allDescendants

on parentOf(elementRef)
    tell application "System Events"
        try
            return value of attribute "AXParent" of elementRef
        on error
            return missing value
        end try
    end tell
end parentOf

on actionNames(elementRef)
    tell application "System Events"
        try
            return name of every action of elementRef
        on error
            return {}
        end try
    end tell
end actionNames

on exactActionButtons(groupRef, exactLabel)
    set matches to {}
    repeat with candidate in my descendants(groupRef)
        if my roleOf(candidate) is "AXButton" then
            set titleText to my attributeText(candidate, "AXTitle")
            set descriptionText to my attributeText(candidate, "AXDescription")
            if titleText is exactLabel or descriptionText is exactLabel then
                set end of matches to candidate
            end if
        end if
    end repeat
    return matches
end exactActionButtons

on repeatBodyCount(groupRef)
    set matches to 0
    repeat with candidate in my descendants(groupRef)
        if my roleOf(candidate) is "AXStaticText" then
            set candidateText to my attributeText(candidate, "AXValue")
            if candidateText starts with "Finished about " then
                if candidateText ends with " ago." or candidateText contains " ago — " then
                    set matches to matches + 1
                end if
            end if
        end if
    end repeat
    return matches
end repeatBodyCount

on defaultPressTargets(groupRef)
    set matches to {}
    set candidates to {groupRef} & my descendants(groupRef)
    repeat with candidate in candidates
        if my roleOf(candidate) is not "AXButton" then
            if my actionNames(candidate) contains "AXPress" then set end of matches to candidate
        end if
    end repeat
    return matches
end defaultPressTargets

on notificationProcess()
    tell application "System Events"
        if not (exists process "NotificationCenter") then my failClosed("notification center unavailable")
        return process "NotificationCenter"
    end tell
end notificationProcess

on run argv
    if (count argv) = 1 and item 1 of argv is "check-permission" then
        tell application "System Events"
            if UI elements enabled is false then my failClosed("accessibility unavailable")
        end tell
        return "authorized"
    end if

    if (count argv) = 2 and item 1 of argv is "count" then
        set exactTitle to item 2 of argv
        set matches to my notificationGroups(my notificationProcess(), exactTitle)
        return "count=" & (count matches)
    end if

    if (count argv) = 2 and item 1 of argv is "count-repeat" then
        set exactTitle to item 2 of argv
        set matches to my notificationGroups(my notificationProcess(), exactTitle)
        if (count matches) is not 1 then return "count=0"
        if my repeatBodyCount(item 1 of matches) is not 1 then return "count=0"
        return "count=1"
    end if

    if (count argv) = 2 and item 1 of argv is "press-default" then
        set exactTitle to item 2 of argv
        set matches to my notificationGroups(my notificationProcess(), exactTitle)
        if (count matches) is not 1 then my failClosed("exact notification match required")
        set pressTargets to my defaultPressTargets(item 1 of matches)
        if (count pressTargets) is not 1 then my failClosed("exact default press target required")
        tell application "System Events" to perform action "AXPress" of item 1 of pressTargets
        return "pressed=default"
    end if

    if (count argv) = 3 and item 1 of argv is "press-action" then
        set exactTitle to item 2 of argv
        set exactLabel to item 3 of argv
        set matches to my notificationGroups(my notificationProcess(), exactTitle)
        if (count matches) is not 1 then my failClosed("exact notification match required")
        set buttons to my exactActionButtons(item 1 of matches, exactLabel)
        if (count buttons) is not 1 then my failClosed("exact action button required")
        tell application "System Events" to perform action "AXPress" of item 1 of buttons
        return "pressed=action"
    end if

    my failClosed("invalid mode")
end run
