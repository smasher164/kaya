# The media player demo (guests/python/music.py): a list's song and album
# counts and its length in words (docs/media-player-plan.md M9, M16 (23)).
songs = { $count ->
    [one] { $count } song
   *[other] { $count } songs
}
albums = { $count ->
    [one] { $count } album
   *[other] { $count } albums
}
length-hours = { $hours } hr { $minutes } min
length-minutes = { $minutes } min { $seconds } sec
length-seconds = { $seconds } sec
songs-length = { $songs }, { $length }
# The controls' help text, the tooltip on the desktops (docs/media-player-plan.md M24).
help-play = Play
help-pause = Pause
help-previous = Previous
help-next = Next
help-shuffle = Shuffle
help-repeat = Repeat
help-like = Like
help-unlike = Remove from Liked Songs
help-mute = Mute
help-unmute = Unmute
help-volume = Volume
help-favorite = Favorite
repeat-off = Repeat off
repeat-all = Repeat all
repeat-one = Repeat one
