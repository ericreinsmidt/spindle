-- Putting the instructions where the music has to go.
--
-- Spindle needs its library prepared on a computer, which means anybody with an
-- empty library is about to plug the device into one. The folder they will land
-- in is the data folder, because that is where the library has to end up. So the
-- instructions and the tool that does the converting are copied into that folder
-- the first time the app finds it empty.
--
-- The alternative was to send people to a web page. This is better for the same
-- reason a manual in the glovebox beats one on a website: it is already where
-- you are when you need it. It also means the app explains itself with no
-- network, no hosting, and nothing to keep alive.
--
-- The files ride along inside the .pdx. pdc copies anything it does not
-- recognize straight into the bundle, so a text file and a Python script arrive
-- untouched, and build.sh copies ingest.py in from tools/ before every compile
-- so the shipped tool cannot drift from the real one.

Docs = {}

-- Read from the bundle, written to the data folder. The Playdate looks in both
-- when opening for reading and only ever writes to the second, which is what
-- makes this a copy out rather than a copy in place.
local FILES_TO_INSTALL <const> = {
    { source = "docs/README.txt", destination = "README.txt" },
    { source = "docs/WINDOWS.txt", destination = "WINDOWS.txt" },
    { source = "docs/ingest.py", destination = "ingest.py" },
}

-- Copied in pieces rather than in one read, because the size of a file in the
-- bundle is not something to assume, and ingest.py is fifty kilobytes.
local COPY_CHUNK_BYTES <const> = 8192


local function copyOutOfBundle(sourcePath, destinationPath)
    -- Never overwrite. Somebody may have edited their copy, and clobbering it on
    -- every launch would be a small betrayal of a file we told them to read.
    if playdate.file.exists(destinationPath) then
        return false
    end

    local source = playdate.file.open(sourcePath, playdate.file.kFileRead)
    if not source then
        return false
    end

    local destination = playdate.file.open(destinationPath, playdate.file.kFileWrite)
    if not destination then
        source:close()
        return false
    end

    while true do
        local chunk = source:read(COPY_CHUNK_BYTES)
        if not chunk or #chunk == 0 then
            break
        end
        destination:write(chunk)
    end

    source:close()
    destination:close()
    return true
end


-- Put the instructions and the conversion tool in the data folder.
--
-- Called only when the library is missing, so it costs nothing on a device that
-- already has music, and it runs once because it will not overwrite what is
-- already there.
--
-- Failures are ignored on purpose. This is a convenience, and an app that
-- refused to start because it could not write a README would be worse than one
-- that quietly did without it.
function Docs.install()
    local installedAny = false
    for _, file in ipairs(FILES_TO_INSTALL) do
        if copyOutOfBundle(file.source, file.destination) then
            installedAny = true
        end
    end
    return installedAny
end
