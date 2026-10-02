--!nonstrict
-- Runtime UI translation facade. Dynamic station and track data is never passed
-- through this table. Only known user-facing English literals are translated.

local uiText = {}

local LITERAL_KEYS = {
    ["Radio Tellus"] = "title",
    ["Internet radio from around the world"] = "subtitle",
    ["Recent popular stations"] = "view.discover",
    ["Pick a mood"] = "view.pick_mood",
    ["Pick a genre"] = "view.pick_genre",
    ["Pick a place"] = "view.pick_place",
    ["Your favorites"] = "view.favorites",
    ["Recently played"] = "view.recent",
    ["Tellus Scrobbler"] = "view.scrobbler",
    ["Recent scrobbles"] = "view.recent_scrobbles",
    ["Discover"] = "nav.discover",
    ["Moods"] = "nav.moods",
    ["Genres"] = "nav.genres",
    ["Places"] = "nav.places",
    ["Favorites"] = "nav.favorites",
    ["Recent"] = "nav.recent",
    ["Scrobbler"] = "nav.scrobbler",
    ["Search station names…"] = "search_placeholder",
    ["Reload stations"] = "reload_stations",
    ["Loading…"] = "loading",
    ["Saving order…"] = "saving_order",
    ["Close"] = "close",
    ["Radio settings"] = "radio_settings",
    ["Open ScuroLabs plugins on GitHub"] = "github_project",
    ["Remove favorite"] = "remove_favorite",
    ["Add favorite"] = "add_favorite",
    ["Connecting…"] = "connecting",
    ["Pause station"] = "pause_station",
    ["Resume station"] = "resume_station",
    ["Play station"] = "play_station",
    ["Drag favorite to reorder"] = "drag_favorite",
    ["Previous"] = "previous",
    ["Next"] = "next",
    ["Mute"] = "mute",
    ["Favorite playing station"] = "favorite_playing",
    ["Random station"] = "random_station",
    ["Play / pause"] = "play_pause",
    ["Stop"] = "stop",
    ["Select a station or choose Random"] = "select_station",
    ["Paused"] = "paused",
    ["Live now"] = "live_now",
    ["Unknown station"] = "unknown_station",
    ["No station playing"] = "no_station",
    ["Waiting for a verified song"] = "waiting_verified_song",
    ["The station's song details will appear here"] = "song_details_pending",
    ["Verified for Last.fm"] = "verified_for_lastfm",
    ["Last.fm saved song"] = "lastfm_saved_song",
    ["Current song"] = "current_song",
    ["Status"] = "status",
    ["Last.fm account"] = "lastfm_account",
    ["Open profile"] = "open_profile",
    ["API key"] = "api_key",
    ["Shared secret"] = "shared_secret",
    ["Last.fm API key"] = "api_key_placeholder",
    ["Last.fm shared secret"] = "shared_secret_placeholder",
    ["Save API credentials"] = "save_credentials",
    ["Authorize Last.fm"] = "authorize_lastfm",
    ["Complete Last.fm authorization"] = "complete_authorization",
    ["Disconnect Last.fm"] = "disconnect_lastfm",
    ["Open Last.fm track"] = "open_track",
    ["Open saved track"] = "open_saved_track",
    ["Radio Tellus checks each song with Last.fm before saving it. Songs waiting to be sent are retained safely and retried after a restart."] = "lastfm_explanation",
    ["Create Last.fm API account"] = "create_api_account",
    ["powered by AudioScrobbler"] = "powered_by_audioscrobbler",
    ["Copy"] = "copy",
    ["Open Last.fm"] = "open_lastfm",
    ["Copy artist and title"] = "copy_artist_title",
    ["Open the Last.fm track page"] = "open_track_page",
    ["No Radio Tellus songs have been saved yet."] = "no_saved_songs",
    ["Back to Scrobbler"] = "back_to_scrobbler",
    ["Chill"] = "mood.chill",
    ["Focus"] = "mood.focus",
    ["Happy"] = "mood.happy",
    ["Energy"] = "mood.energy",
    ["Calm"] = "mood.calm",
    ["Sleep"] = "mood.sleep",
    ["Romantic"] = "mood.romantic",
    ["Melancholy"] = "mood.melancholy",
    ["Pop"] = "genre.pop",
    ["Rock"] = "genre.rock",
    ["Electronic"] = "genre.electronic",
    ["Hip-hop"] = "genre.hiphop",
    ["Jazz"] = "genre.jazz",
    ["Classical"] = "genre.classical",
    ["Soul & R&B"] = "genre.soul_rnb",
    ["Reggae"] = "genre.reggae",
    ["Metal"] = "genre.metal",
    ["Folk"] = "genre.folk",
    ["Country"] = "genre.country",
    ["Talk"] = "genre.talk",
    ["Sweden"] = "place.sweden",
    ["United Kingdom"] = "place.united_kingdom",
    ["United States"] = "place.united_states",
    ["France"] = "place.france",
    ["Germany"] = "place.germany",
    ["Spain"] = "place.spain",
    ["Italy"] = "place.italy",
    ["Brazil"] = "place.brazil",
    ["Japan"] = "place.japan",
    ["India"] = "place.india",
    ["Australia"] = "place.australia",
    ["Canada"] = "place.canada",
    ["Russia"] = "place.russia",
    ["South Korea"] = "place.south_korea",
    ["North Korea"] = "place.north_korea",
    ["Iran"] = "place.iran",
    ["Syria"] = "place.syria",
    ["Laos"] = "place.laos",
    ["Moldova"] = "place.moldova",
    ["Tanzania"] = "place.tanzania",
    ["Venezuela"] = "place.venezuela",
    ["Bolivia"] = "place.bolivia",
    ["Vietnam"] = "place.vietnam",
    ["Brunei"] = "place.brunei",
    ["Czechia"] = "place.czechia",
    ["Netherlands"] = "place.netherlands",
    ["Vatican City"] = "place.vatican_city",
    ["This station has no playable stream."] = "errors.station_no_stream",
    ["This station has an invalid stream address and cannot be played."] = "errors.station_invalid_stream",
    ["This station has an unsafe stream address and cannot be played."] = "errors.station_unsafe_stream",
    ["This station uses a direct network address that Radio Tellus cannot play. Try another station."] = "errors.station_direct_address",
    ["This station points to a private or reserved address and cannot be played."] = "errors.station_private_address",
    ["This station points to a local address and cannot be played."] = "errors.station_local_address",
    ["This station does not use a secure connection. Enable HTTP streams in Radio settings only if you trust the station."] = "errors.station_insecure",
    ["The station directory did not respond correctly. Try again later."] = "errors.directory_invalid_response",
    ["The station directory sent too much data. Try again later."] = "errors.directory_oversized",
    ["Could not load the station directory. Check your connection and try again."] = "errors.directory_load",
    ["Could not start the station directory request. Try again."] = "errors.directory_start",
    ["The station directory sent data Radio Tellus could not use. Try again later."] = "errors.directory_invalid_data",
    ["Live internet radio"] = "station.live_internet_radio",
    ["HTTP"] = "station.http",
    ["The current station is still connecting. Stop it before choosing another station."] = "errors.station_still_connecting",
    ["The station could not start playing. Try another station."] = "errors.station_start",
    ["The station could not be stopped. Try stopping it again."] = "errors.station_stop",
    ["Your station queue could not be saved. Try again."] = "errors.queue_save",
    ["Your volume setting could not be saved. Try again."] = "errors.volume_save",
    ["Could not find a random station. Try again."] = "errors.random_not_found",
    ["Could not start finding a random station. Try again."] = "errors.random_start",
    ["Could not start loading stations. Try again."] = "errors.load_start",
    ["No playable stations found."] = "errors.no_playable_stations",
    ["Could not load stations. Check your connection and try again."] = "errors.load_stations",
    ["No stations matched."] = "errors.no_stations_matched",
    ["Could not queue the favorite reorder. Try again."] = "errors.favorite_reorder_queue",
    ["Favorite reorder was rejected."] = "errors.favorite_reorder_rejected",
    ["Could not open the Radio Tellus GitHub project."] = "errors.github_open",
    ["Could not open the Last.fm API account page."] = "errors.lastfm_api_open",
    ["Could not open the Last.fm website."] = "errors.lastfm_site_open",
    ["Could not open the Last.fm profile."] = "errors.lastfm_profile_open",
    ["Could not open the Last.fm track page."] = "errors.lastfm_track_open",
    ["Could not open the saved Last.fm track page."] = "errors.lastfm_saved_track_open",
    ["This scrobble has no copyable song details."] = "errors.scrobble_no_details",
    ["Copied the song artist and title to the clipboard."] = "notifications.scrobble_copied",
    ["Could not copy the song artist and title to the clipboard."] = "errors.scrobble_copy",
    ["This scrobble has no Last.fm page."] = "errors.scrobble_no_page",
    ["Updated just now"] = "updated_just_now",
    ["Loading stations…"] = "loading_stations",
    ["Saving order…"] = "saving_order",
    ["Page"] = "page",
    ["Radio Tellus cannot check playback right now. Audio may still be playing."] = "errors.playback_check",
    ["Radio Tellus is reconnecting to the station."] = "playback.reconnecting",
    ["Connecting to the station. Waiting for audio."] = "playback.connecting",
    ["An older station session was stopped because it did not meet Radio Tellus safety requirements."] = "errors.older_session_stopped",
    ["The previous station could not be stopped, so the new station was not started. Try stopping it again."] = "errors.previous_station_stop",
    ["Radio Tellus could not prepare the new station. Try again."] = "errors.prepare_station",
    ["There are no stations in the queue yet."] = "errors.empty_queue",
    ["Open Radio Tellus once to load recent stations, then try again."] = "launcher.open_to_load",
    ["No saved station is currently safe to play. Open Radio Tellus to refresh the station list."] = "launcher.no_safe_station",
    ["Could not remove songs waiting to be sent to Last.fm. Try again."] = "errors.lastfm_queue_remove",
    ["Could not remove the saved Last.fm settings. Try again."] = "errors.lastfm_settings_remove",
    ["Could not read the saved Last.fm settings. Try saving them again."] = "lastfm.credentials_could_not_be_loaded",
    ["Enter the Last.fm API key and shared secret first."] = "errors.lastfm_credentials_required",
    ["Last.fm authorization could not be started. Check your Last.fm details and try again."] = "errors.lastfm_authorization_start",
    ["Could not prepare Last.fm authorization. Try again."] = "errors.lastfm_authorization_prepare",
    ["Could not open Last.fm in your browser. Try authorization again."] = "errors.lastfm_browser_open",
    ["Approve access in Last.fm, then choose Finish authorization."] = "lastfm.authorization_waiting",
    ["Start authorization first, then approve access in Last.fm."] = "errors.lastfm_authorization_first",
    ["Last.fm authorization did not complete. Try again."] = "lastfm.messages.lastfm_session_missing",
    ["Last.fm could not finish connecting this account. Try again."] = "errors.lastfm_connect",
    ["Check your internet connection and try again."] = "errors.lastfm_network",
    ["Last.fm sent an unexpected reply. Try again later."] = "lastfm.messages.response_invalid",
    ["Last.fm did not accept the request. Try again later."] = "lastfm.messages.request_rejected",
    ["The Last.fm API key does not look valid."] = "errors.lastfm_api_key",
}

local function translateLiteral(value)
    if type(value) ~= "string" then return value end
    local key = LITERAL_KEYS[value]
    return key == nil and value or noctalia.tr("ui." .. key)
end

function uiText.tr(key, substitutions)
    return noctalia.tr("ui." .. key, substitutions)
end

function uiText.literal(value)
    return translateLiteral(value)
end

function uiText.notify(title, message, isError)
    local translatedTitle = translateLiteral(title)
    local translatedMessage = translateLiteral(message)
    if isError and type(noctalia.notifyError) == "function" then
        noctalia.notifyError(translatedTitle, translatedMessage)
    else
        noctalia.notify(translatedTitle, translatedMessage)
    end
end

local function translatedProperties(properties)
    if type(properties) ~= "table" then return properties end
    local copy = {}
    for key, value in pairs(properties) do copy[key] = value end
    for _, key in ipairs({ "text", "tooltip", "placeholder" }) do
        if copy[key] ~= nil then copy[key] = translateLiteral(copy[key]) end
    end
    return copy
end

function uiText.wrap(nativeUi)
    local wrapped = {}
    for key, value in pairs(nativeUi) do wrapped[key] = value end
    for _, name in ipairs({ "button", "input", "label" }) do
        local constructor = nativeUi[name]
        wrapped[name] = function(properties, ...)
            return constructor(translatedProperties(properties), ...)
        end
    end
    return wrapped
end

return uiText
