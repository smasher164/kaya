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
