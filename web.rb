# coding: utf-8
require 'sinatra'
require 'RMagick'
require 'uri'
require 'net/http'
require 'json'
require 'dalli'
require 'set'

use Rack::Static, :urls => ['/favicon.ico', '/robots.txt', '/css', '/js', '/img'], :root => 'public'
IMAGE_NUM_MAX = 15

def editImage(command, url, commandHash, image)
    begin
        if commandHash.key?('rectangle') then
            args = commandHash['rectangle']
            if args.instance_of?(Hash) then
                args = [args]
            end
            for arg in args do
                draw = Magick::Draw.new
                draw.fill = arg.fetch('color', '#FFFFFF')
                draw.rectangle(arg.fetch('x1', 0).to_i, arg.fetch('y1', 0).to_i, arg.fetch('x2', 0).to_i, arg.fetch('y2', 0).to_i)
                draw.draw(image)
            end
        end

        if commandHash.key?('annotate') then
            args = commandHash['annotate']
            if args.instance_of?(Hash) then
                args = [args]
            end
            for arg in args do
                lines = arg['text'].split
                j = 1
                for line in lines do
                    fontSize = arg.fetch('size', 30).to_i
                    draw = Magick::Draw.new
                    draw.annotate(image, image.columns, image.rows, arg.fetch('x', 0).to_i, arg.fetch('y', 0).to_i + fontSize * j, line) do
                        self.font = 'fonts/ipaexg.ttf'
                        self.fill = arg.fetch('color', '#000000')
                        self.pointsize = fontSize
                    end
                    j += 1
                end
            end
        end

        if commandHash.key?('tategaki') then
            args = commandHash['tategaki']
            if args.instance_of?(Hash) then
                args = [args]
            end
            for arg in args do
                if arg.key?('text') then
                    lines = arg['text'].split
                    j = 0
                    for line in lines do
                        fontSize = arg.fetch('size', 30).to_i
                        draw = Magick::Draw.new
                        i = 0
                        while i < line.size
                            draw.annotate(image, image.columns, image.rows, arg.fetch('x', 0).to_i - fontSize * j, arg.fetch('y', 0).to_i + fontSize * (i + 1), line[i]) do
                                self.font = 'fonts/ipaexg.ttf'
                                self.align = Magick::CenterAlign
                                self.fill = arg.fetch('color', '#000000')
                                self.pointsize = fontSize
                            end
                            i += 1
                        end
                        j += 1
                    end
                end
            end
        end
    rescue Exception => e
        logger.error e.to_s
        halt 500, 'image edit error'
    end

    begin
        if command then
            dc = Dalli::Client.new(
                ENV['MEMCACHIER_SERVERS'],
                {:username => ENV['MEMCACHIER_USERNAME'], :password => ENV['MEMCACHIER_PASSWORD']}
            )
            imageSet = dc.get('set')
            unless imageSet
                imageSet = Set.new
            end
            if imageSet.length > IMAGE_NUM_MAX
                tmp = imageSet.to_a.shift
                tmp.push("/image/v1/#{URI.encode(command)}/#{URI.encode(url)}")
                imageSet = Set.new(tmp)
            else
                imageSet.add("/image/v1/#{URI.encode(command)}/#{URI.encode(url)}")
            end
            dc.set('set', imageSet)
        end
    rescue Exception => e
        logger.warn e.to_s
    end
end

get '/' do
    begin
        dc = Dalli::Client.new(
            ENV['MEMCACHIER_SERVERS'],
            {:username => ENV['MEMCACHIER_USERNAME'], :password => ENV['MEMCACHIER_PASSWORD']}
        )
        imageSet = dc.get('set')
    rescue Exception => e
        logger.warn e.to_s
    end
    unless imageSet
        imageSet = Set.new
    end
    erb :index, :locals => {:images => imageSet}
end

get '/readme' do
    erb :readme
end

get '/make' do
    erb :make
end

get '/proxy' do
    unless params.has_key?('url')
        halt 400, 'bad parameter'
    end

    begin
        uri = URI.parse(params['url'])
        #if /^.+¥.jpg¥.to$/ =~ uri.host
        #end
        response = Net::HTTP.start(uri.host, uri.port) {|http|
            http.get(uri.path)
        }
    rescue Exception => e
        logger.error e.to_s
        halt 500, 'url error'
    end

    content_type response.content_type
    #同ドメインになるのでつけなくてもいいけど
    headers['Access-Control-Allow-Origin'] = '*'
    response.body
end

get '/image/v1' do
    command = params['command']
    url = params['url']

    image = nil, response = nil, commandHash = nil
    if url then
        begin
            uri = URI.parse(url)
            response = Net::HTTP.start(uri.host, uri.port) {|http|
                http.get(uri.path)
            }
            image = Magick::Image.from_blob(response.body).shift
        rescue Exception => e
            logger.info url
            logger.error e.to_s
            halt 500, 'url error'
        end
    else
        halt 400, 'no url parameter'
    end

    if command then
        begin
            commandHash = JSON.parse(command)
        rescue Exception => e
            logger.error e.to_s
            halt 400, 'command error'
        end
    end

    begin
        i = url.index('http')
        unless i || i != 0 then
            url = 'http://' + url
        else
            unless url.index('://') then
                url = url.sub(':/', '://')
            end
        end
        uri = URI.parse(url)
        response = Net::HTTP.start(uri.host, uri.port) {|http|
            http.get(uri.path)
        }
        image = Magick::Image.from_blob(response.body).shift
    rescue Exception => e
        logger.info url
        logger.error e.to_s
        halt 500, 'url error'
    end

    editImage(command, url, commandHash, image)

    headers['Access-Control-Allow-Origin'] = '*'
    content_type response.content_type
    cache_control :public
    image.to_blob
end

get '/image/v1/*/*' do |command, url|
    begin
        commandHash = JSON.parse(command)
    rescue Exception => e
        logger.error e.to_s
        halt 400, 'command error'
    end

    begin
        unless url.index('http') then
            url = 'http://' + url
        else
            unless url.index('://') then
                url = url.sub(':/', '://')
            end
        end
        uri = URI.parse(url)
        response = Net::HTTP.start(uri.host, uri.port) {|http|
            http.get(uri.path)
        }
        image = Magick::Image.from_blob(response.body).shift
    rescue Exception => e
        logger.info url
        logger.error e.to_s
        halt 500, 'url error'
    end

    editImage(command, url, commandHash, image)

    headers['Access-Control-Allow-Origin'] = '*'
    content_type response.content_type
    cache_control :public
    image.to_blob
end

get '/clear/mem' do
    begin
        dc = Dalli::Client.new(
            ENV['MEMCACHIER_SERVERS'],
            {:username => ENV['MEMCACHIER_USERNAME'], :password => ENV['MEMCACHIER_PASSWORD']}
        )
        dc.flush
    rescue Exception => e
        logger.error e.to_s
        halt 500, 'NG'
    end

    'OK'
end