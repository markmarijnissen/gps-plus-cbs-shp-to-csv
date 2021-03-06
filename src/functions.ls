prompt = require('prompt')
_ = require 'prelude-ls'
shp = require 'shp'
colors = require('colors')
rd = require './rd'
csv = require 'csv'
fs = require 'graceful-fs'
pointInPolygon = require('./pointInPolygon')

config =
    delimiter: ","
    quotechar: '"'
    lineterminator: "\r\n"
    alwaysquote: no
    notfound: '-9'

lat-index = -1
lng-index = -1

csv-field = (string) -> 
  string = string+""
  regex = new RegExp(config.quotechar,'g')
  string = string.replace regex,config.quotechar+config.quotechar
  if config.alwaysquote or string.match("(#{config.quotechar}|#{config.delimiter}|#{config.lineterminator})") isnt null
    string = config.quotechar+string+config.quotechar
  string

write-csv-row = (stream,values) ->
  row =_.map(csv-field,values).join(config.delimiter)+config.lineterminator
  stream.write row

create-header = (stream,row,properties) ->
  lat-index := row.length-2
  lng-index := row.length-1
  for name,index in row
    if name is /^lat(itude)?/i then
      lat-index := index
    else if name is /^lo?ng(itude)?/i then
      lng-index := index
  console.log "Extracting latitude from ".cyan+row[lat-index].cyan.bold+" (column \##{lat-index+1})".cyan
  console.log "Extracting longitude from ".cyan+row[lng-index].cyan.bold+" (column \##{lng-index+1})".cyan
  columns = row ++ [key.trim! for key,value of properties]
  write-csv-row(stream,columns)

create-record-callback = (stream,data,stats) -> 
  (row,index) ->
    # write header
    if index is 0 then
      console.log "converting...".yellow
      create-header(stream,row, data.features[0].properties)
      return

    if index % 1000 is 0 then
      console.log "...#index rows...".grey

    stats.total++
    # calculate RD from GPS
    [lat,lng] = [row[lat-index],row[lng-index]]
    x = rd.x(lat,lng)
    y = rd.y(lat,lng)

    # double check notification
    suspicious = false
    if x > y or Math.abs(lat-53) > 4 or Math.abs(lng-5) > 4 then
      if stats.suspicious is 0
        console.log "Warning: Suspicious latitude,longitude".yellow
        console.log "Latitude = #{lat} (~55); Longitude = #{lng} (~5)".grey
        console.log "RD-X = #{x}, RD-Y = #{y}".grey
      else if stats.suspicious is 1
        console.log "Warning: More suspicious latitude,longitude found...".yellow
      stats.suspicious++
      suspicious = true

    # hit test until found, then write row
    valid = false
    if not suspicious
      for item in data.features 
        if pointInPolygon(item.geometry.coordinates[0],x,y)
          values = row ++ [value.trim! for key,value of item.properties]
          write-csv-row(stream,values)
          valid = true
          break
    if not valid
      #console.log "Warning: Could not link (#lat,#lng) to any data.".yellow
      stats.link++
      values = row ++ [config.notfound for key,value of data.features[0].properties]
      write-csv-row(stream,values)

module.exports =
  config: config

  cbs-to-csv: (args) ->
    console.log "reading *.shp...".yellow
    (err,data) <- shp.readFile args.shp
    if err then
      console.error "Error parsing #{args.shp}:".red,err
      process.exit(1)
      return

    stream = fs.createWriteStream(args.output)
    stream.on 'error', (err) -> console.error "Error writing #{args.output}",err.message
    
    (fd) <- stream.once 'open'
    count = 0
    write-csv-row(stream,[key.trim! for key,value of data.features[0].properties])
    for item in data.features
      values = [value.trim! for key,value of item.properties]
      write-csv-row(stream,values)
      count++
    stream.end!
    console.log "Done! Extracted #count rows of data.".green.bold 

  add-cbs-to-csv: (args) ->
    console.log "reading *.shp...".yellow
    (err,data) <- shp.readFile args.shp
    if err then
      console.error "Error parsing #{args.shp}:".red,err
      process.exit(1)
      return

    console.log "reading *.csv...".yellow

    stream = fs.createWriteStream(args.output)
    stream.on 'error', (err) -> console.error "Error writing #{args.output}",err.message
    stats = { total: 0, link: 0, suspicious: 0}
    (fd) <- stream.once 'open'
    csv()
      ..from.path(args.input)
      ..on 'record', create-record-callback(stream,data,stats)
      ..on 'end', -> 
          stream.end!
          if stats.suspicious > 0 then
            console.error "Warning: Found #{stats.suspicious} suspicious GPS coordinates!".yellow
          if stats.link > 0 then
            console.error "Warning: Could not link #{stats.link} rows to any data!".yellow
          console.log "Done! Converted #{stats.total} rows.".green.bold
      ..on 'error', (err) -> console.error "Error parsing #{args.input}:".red,arguments,err.message    

  run: (args,func) ->
    input = false
    if process.argv.length is 5
      try
        input.input = require("./"+process.argv[2])
        input.shp = require("./"+process.argv[3])
        input.output = require('./'+process.argv[4])
    if not input
      prompt.start!
      (err,input) <- prompt.get args
      func(input)
    else
      func(input)