_ = require 'underscore'
s3 = require 's3'
fs = require 'fs'
path = require 'path'
request = require 'request'
Promise = require 'bluebird'

s3Client = null

module.exports = (grunt) ->
  {cp, spawn, rm} = require('./task-helpers')(grunt)

  getVersion = ->
    {version} = require(path.join(grunt.config.get('atom.appDir'), 'package.json'))
    return version

  appName = -> grunt.config.get('atom.appName')
  dmgName = -> "#{appName().split('.')[0]}.dmg"
  zipName = -> "#{appName().split('.')[0]}.zip"
  winReleasesName = -> "RELEASES"
  winSetupName = -> "Nylas N1Setup.exe"
  winNupkgName = -> "nylas-#{getVersion()}-full.nupkg"

  runEmailIntegrationTest = ->
    return Promise.resolve() unless process.platform is 'darwin'

    buildDir = grunt.config.get('atom.buildDir')
    buildVersion = getVersion()
    new Promise (resolve, reject) ->
      appToRun = path.join(buildDir, appName())
      scriptToRun = "./build/run-build-and-send-screenshot.scpt"
      spawn
        cmd: "osascript"
        args: [scriptToRun, appToRun, buildVersion]
      , (error) ->
        if error
          reject(error)
          return
        resolve()

  postToSlack = (msg) ->
    new Promise (resolve, reject) ->
      url = "https://hooks.slack.com/services/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"
      request.post
        url: url
        json:
          username: "Edgehill Builds"
          text: msg
      , (err, httpResponse, body) ->
        if err then reject(err)
        else resolve()

  put = (localSource, destName) ->
    grunt.log.writeln ">> Uploading #{localSource} to S3…"

    write = grunt.log.writeln
    ext = path.extname(destName)
    lastPc = 0

    new Promise (resolve, reject) ->
      uploader = s3Client.uploadFile
        localFile: localSource
        s3Params:
          Key: destName
          ACL: "public-read"
          Bucket: "edgehill"
          ContentDisposition:"attachment; filename=\"N1#{ext}\""

      uploader.on "error", (err) ->
        reject(err)
      uploader.on "progress", ->
        pc = Math.round(uploader.progressAmount / uploader.progressTotal * 100.0)
        if pc isnt lastPc
          lastPc = pc
          write(">> Uploading #{destName} #{pc}%")
      uploader.on "end", (data) ->
        resolve(data)

  uploadToS3 = (filename, key) ->
    filepath = path.join(grunt.config.get('atom.buildDir'), filename)

    grunt.log.writeln ">> Uploading #{filename} to #{key}…"
    put(filepath, key).then (data) ->
      msg = "N1 release asset uploaded: <#{data.Location}|#{filename}>"
      postToSlack(msg).then ->
        Promise.resolve(data)

  uploadZipToS3 = (filename, key) ->
    filepath = path.join(grunt.config.get('atom.buildDir'), filename)

    grunt.log.writeln ">> Creating zip file…"
    new Promise (resolve, reject) ->
      zipFilepath = filepath + ".zip"
      rm(zipPath)
      orig = process.cwd()
      process.chdir(buildDir)

      spawn
        cmd: "zip"
        args: ["-9", "-y", "-r", zipFilepath, filepath]
      , (error) ->
        process.chdir(orig)
        if error
          reject(error)
          return

        grunt.log.writeln ">> Created #{zipPath}"
        grunt.log.writeln ">> Uploading…"
        uploadToS3(zipFilepath, key).then(resolve).catch(reject)

  grunt.registerTask "publish-nylas-build", "Publish Nylas build", ->
    awsKey = process.env.AWS_ACCESS_KEY_ID ? ""
    awsSecret = process.env.AWS_SECRET_ACCESS_KEY ? ""

    if awsKey.length is 0
      grunt.log.error "Please set the AWS_ACCESS_KEY_ID environment variable"
      return false
    if awsSecret.length is 0
      grunt.log.error "Please set the AWS_SECRET_ACCESS_KEY environment variable"
      return false

    s3Client = s3.createClient
      s3Options:
        accessKeyId: process.env.AWS_ACCESS_KEY_ID
        scretAccessKey: process.env.AWS_SECRET_ACCESS_KEY

    done = @async()

    runEmailIntegrationTest().then ->
      uploadPromises = []
      if process.platform is 'darwin'
        uploadPromises.push uploadToS3(dmgName(), "#{process.platform}/N1-#{getVersion()}.dmg")
        uploadPromises.push uploadZipToS3(appName(), "#{process.platform}/N1-#{getVersion()}.zip")
      if process.platform is 'win32'
        uploadPromises.push uploadToS3("installer/"+winReleasesName(), "#{process.platform}/nylas-#{getVersion()}-RELEASES.txt")
        uploadPromises.push uploadToS3("installer/"+winSetupName(), "#{process.platform}/nylas-#{getVersion()}.exe")
        uploadPromises.push uploadToS3("installer/"+winNupkgName(), "#{process.platform}/#{winNupkgName()}")

      Promise.all(uploadPromises).then(done).catch (err) ->
        grunt.log.error(err)
        return false
