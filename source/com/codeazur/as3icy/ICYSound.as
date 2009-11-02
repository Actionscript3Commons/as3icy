﻿package com.codeazur.as3icy 
{
	import com.codeazur.as3icy.data.MPEGFrame;
	import com.codeazur.as3icy.decoder.Decoder;
	import com.codeazur.as3icy.decoder.OutputBuffer;
	import com.codeazur.as3icy.events.ICYFrameEvent;
	import com.codeazur.as3icy.events.ICYMetaDataEvent;
	import com.codeazur.utils.StringUtils;
	import flash.display.DisplayObject;
	import flash.display.Sprite;
	
	import flash.display.Loader;
	import flash.display.LoaderInfo;
	import flash.events.*;
	import flash.media.Sound;
	import flash.media.SoundLoaderContext;
	import flash.net.URLRequest;
	import flash.net.URLRequestHeader;
	import flash.net.URLStream;
	import flash.system.LoaderContext;
	import flash.utils.ByteArray;
	import flash.utils.Endian;
	import flash.utils.Timer;
	
	public class ICYSound extends Sound
	{
		protected static const FRAME_BUFFER_MAX:uint = 20;
		protected static const SAMPLE_DATA_SIZE:uint = 8192;
		protected static const SAMPLE_DATA_BYTES:uint = (SAMPLE_DATA_SIZE << 3);
		
		protected var stream:URLStream;
		
		protected var _mpegFrame:MPEGFrame;
		
		protected var headerIndex:uint = 0;
		protected var crcIndex:uint = 0;
		
		protected var _meta:String = "";
		protected var _framesLoaded:uint = 0;
		protected var _metaDataLoaded:uint = 0;
		protected var _metaDataBytesLoaded:uint = 0;

		protected var responseUrl:String = "";
		
		protected var _icyMetaSize:uint = 0;
		protected var _icyMetaInterval:uint = 0;
		protected var _icyName:String = "";
		protected var _icyDescription:String = "";
		protected var _icyUrl:String = "";
		protected var _icyGenre:String = "";
		protected var _icyBitrate:uint = 0;
		protected var _icyPublish:Boolean = false;
		protected var _icyServer:String = "";
		
		protected var readFunc:Function = readIdle;
		protected var readFuncContinue:Function;
		
		protected var icyHeader:ByteArray;
		protected var icyCRReceived:Boolean = false;
		protected var icyCRLFCount:uint = 0;

		protected var read:uint = 0;
		protected var paused:Boolean = false;
		protected var frameDataTmp:ByteArray;
		
		protected var sampleBuffer:ByteArray;
		
		protected var buffering:Boolean = true;
		
		protected var decoder:Decoder;

		protected var dobj:Sprite;
		
		public function ICYSound(request:URLRequest = null, context:SoundLoaderContext = null) 
		{
			super(null, context);
			dobj = new Sprite();
			if (request != null) {
				load(request, context);
			}
		}
		
		
		override public function load(request:URLRequest, context:SoundLoaderContext = null):void {
			if (request == null) { return; }
			sampleBuffer = new ByteArray();
			decoder = new Decoder(new OutputBuffer());
			_mpegFrame = new MPEGFrame();
			read = 0;
			frameDataTmp = null;
			icyHeader = null;
			icyCRReceived = false;
			icyCRLFCount = 0;
			_framesLoaded = 0;
			_metaDataLoaded = 0;
			_metaDataBytesLoaded = 0;
			responseUrl = request.url;
			try { stream.close(); } catch (e:Error) { }
			stream = new URLStream();
			stream.addEventListener(ProgressEvent.PROGRESS, progressHandler);
			stream.addEventListener(Event.COMPLETE, completeHandler);
			stream.addEventListener(HTTPStatusEvent.HTTP_STATUS, defaultHandler);
			stream.addEventListener(IOErrorEvent.IO_ERROR, defaultHandler);
			stream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, defaultHandler);
			stream.addEventListener(Event.OPEN, openHandler);
			CONFIG::AIR {
				stream.addEventListener(HTTPStatusEvent.HTTP_RESPONSE_STATUS, httpResponseStatusHandler);
			}
			addEventListener(SampleDataEvent.SAMPLE_DATA, sampleDataHandler, false, int.MAX_VALUE);
			stream.load(request);
		}
		
		protected function sampleDataHandler(e:SampleDataEvent):void {
			var i:uint = 0;
			var bytesToServe:uint = 0;
			if(buffering) {
				if(sampleBuffer.length > SAMPLE_DATA_BYTES * 2) {
					writeSampleData(e.data, SAMPLE_DATA_BYTES);
					buffering = false;
				} else {
					for(i = 0; i < SAMPLE_DATA_SIZE; i++) {
						e.data.writeFloat(0);
						e.data.writeFloat(0);
					}
				}
			} else {
				var len:uint = writeSampleData(e.data, SAMPLE_DATA_BYTES);
				if(len < SAMPLE_DATA_BYTES) {
					var size:uint = (len >> 3);
					for(i = 0; i < SAMPLE_DATA_SIZE - size; i++) {
						e.data.writeFloat(0);
						e.data.writeFloat(0);
					}
					buffering = true;
				}
			}
		}
		
		protected function writeSampleData(soundBuffer:ByteArray, len:uint):uint {
			if(len > 0 && sampleBuffer.length > 0) {
				len = Math.min(len, sampleBuffer.length);
				soundBuffer.writeBytes(sampleBuffer, 0, len);
				if(len == sampleBuffer.length) {
					sampleBuffer = new ByteArray();
				} else {
					var ba:ByteArray = new ByteArray();
					ba.writeBytes(sampleBuffer, len, sampleBuffer.length - len);
					sampleBuffer = ba; 
				}
			} else {
				len = 0;
			}
			return len;
		}

		override public function close():void {
			stream.close();
		}
		
		public function resume():void {
			if (paused && stream.connected) {
				paused = false;
				_mpegFrame = new MPEGFrame();
				readFunc = readFrameHeader;
				readLoop();
			}
		}
		
		public function get connected():Boolean { 
			return (stream != null) ? stream.connected : false;
		}

		public function get mpegFrame():MPEGFrame { return _mpegFrame; }
		
		public function get framesLoaded():uint { return _framesLoaded; }
		public function get metaDataLoaded():uint { return _metaDataLoaded; }
		public function get metaDataBytesLoaded():uint { return _metaDataBytesLoaded; }
		
		public function get icyMetaSize():uint { return _icyMetaSize; }
		public function get icyMetaInterval():uint { return _icyMetaInterval; }
		public function get icyName():String { return _icyName; }
		public function get icyDescription():String { return _icyDescription; }
		public function get icyUrl():String { return _icyUrl; }
		public function get icyGenre():String { return _icyGenre; }
		public function get icyBitrate():uint { return _icyBitrate; }
		public function get icyPublish():Boolean { return _icyPublish; }
		public function get icyServer():String { return _icyServer; }

		
		protected function set meta(value:String):void {
			_meta = value;
		}
		protected function get meta():String {
			return _meta;
		}
		

		CONFIG::AIR {
			protected function httpResponseStatusHandler(e:HTTPStatusEvent):void {
				if (e.responseHeaders.length > 0) {
					processResponseHeaders(e.responseHeaders);
					dispatchEvent(e.clone());
					readFunc = readFrameHeader;
				} else {
					// no response headers probably mean that we're dealing with
					// fucked up non-http ICY responses (ICY 200 OK), so we have to  
					// manually parse the headers. Well, ok then.
					responseUrl = e.responseURL;
					icyHeader = new ByteArray();
					readFunc = readNonHttpIcyHeaderOmgWtfLol;
				}
			}
		}
		
		protected function openHandler(e:Event):void {
			dispatchEvent(e.clone());
			readFunc = readFrameHeader;
		}
		
		protected function completeHandler(e:Event):void {
			dispatchEvent(e.clone());
		}
		
		protected function progressHandler(e:ProgressEvent):void {
			dispatchEvent(e.clone());
			if (!paused && readLoop()) {
				close();
			}
		}
		
		protected function readLoop():Boolean {
			while (readFunc());
			return (readFunc === readIdle);
		}
		
		protected function readIdle():Boolean {
			return false;
		}

		CONFIG::AIR {
			protected function readNonHttpIcyHeaderOmgWtfLol():Boolean {
				while (stream.bytesAvailable) {
					var b:uint = stream.readUnsignedByte();
					if (b == 0x0d) {
						icyCRReceived = true;
					} else if (b == 0x0a) {
						icyHeader.writeByte(b);
						icyCRLFCount++;
					} else {
						icyHeader.writeByte(b);
						icyCRReceived = false;
						icyCRLFCount = 0;
					}
					if (icyCRLFCount == 2) {
						icyHeader.position = 0;
						var responseHeaders:Array = [];
						var header:String = icyHeader.readUTFBytes(icyHeader.length);
						var items:Array = header.split(String.fromCharCode(0x0a));
						for (var i:uint = 0; i < items.length; i++) {
							var item:String = items[i];
							var j:int = item.indexOf(":");
							if (j > 0) {
								var name:String = StringUtils.trim(item.substring(0, j));
								var value:String = StringUtils.trim(item.substring(j + 1));
								responseHeaders.push(new URLRequestHeader(name, value));
							}
						}
						processResponseHeaders(responseHeaders);
						var e:HTTPStatusEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, false, false, 200);
						e.responseHeaders = responseHeaders;
						e.responseURL = responseUrl;
						dispatchEvent(e);
						readFunc = readFrameHeader;
						break;
					}
				}
				return true;
			}
		}
		
		protected function readFrameHeader():Boolean {
			var ret:Boolean = true;
			if (stream.bytesAvailable >= 1) {
				if (icyMetaInterval > 0 && ++read > icyMetaInterval) {
					readFuncContinue = readFrameHeader;
					readFunc = readMetaDataSize;
					return ret;
				}
				try {
					mpegFrame.setHeaderByteAt(headerIndex, stream.readUnsignedByte());
					if (++headerIndex == 4) {
						readFunc = mpegFrame.hasCRC ? readCRC : readFrame;
						headerIndex = 0;
					}
				}
				catch (e:Error) {
					//trace(e.message);
					headerIndex = 0;
				}
			} else {
				ret = false;
			}
			return ret;
		}
		
		protected function readCRC():Boolean {
			var ret:Boolean = true;
			if (stream.bytesAvailable >= 1) {
				if (icyMetaInterval > 0 && ++read > icyMetaInterval) {
					readFuncContinue = readCRC;
					readFunc = readMetaDataSize;
					return ret;
				}
				try {
					mpegFrame.setCRCByteAt(crcIndex, stream.readUnsignedByte());
					if (++crcIndex == 2) {
						readFunc = readFrame;
						crcIndex = 0;
					}
				}
				catch (e:Error) {
					//trace(e.message);
					readFunc = readFrameHeader;
					crcIndex = 0;
				}
			} else {
				ret = false;
			}
			return ret;
		}

		protected function readFrame():Boolean {
			var ret:Boolean = true;
			var readTmp:uint = read;
			var len:uint = mpegFrame.size;
			if (icyMetaInterval > 0) {
				if (frameDataTmp != null) {
					len -= frameDataTmp.length;
				}
				read += len;
				if (read >= icyMetaInterval) {
					len -= (read - icyMetaInterval);
					if (len == 0) {
						read = readTmp;
						frameDataTmp = frameData;
						readFuncContinue = readFrame;
						readFunc = readMetaDataSize;
						return ret;
					}
				}
			}
			if (stream.bytesAvailable >= len) {
				var frameData:ByteArray = new ByteArray();
				if (icyMetaInterval > 0 && frameDataTmp != null) {
					stream.readBytes(frameDataTmp, frameDataTmp.length, len);
					frameData = frameDataTmp;
				} else {
					stream.readBytes(frameData, 0, len);
				}
				if (icyMetaInterval > 0 && read >= icyMetaInterval) {
					frameDataTmp = frameData;
					readFuncContinue = readFrame;
					readFunc = readMetaDataSize;
				} else {
					_framesLoaded++;
					frameDataTmp = null;
					mpegFrame.data.writeBytes(frameData);
					mpegFrame.data.position = 0;

					// decode the mpeg frame we just read
					decoder.decodeFrame(mpegFrame);
					
					var ob:Vector.<Number> = decoder.outputBuffer.getBuffer();
					for (var i:uint = 0; i < ob.length; i++) {
						sampleBuffer.writeFloat(ob[i]);
					}
					decoder.outputBuffer.clear_buffer();

					dispatchEvent(new ICYFrameEvent(ICYFrameEvent.FRAME, mpegFrame, false, true));

					if (sampleBuffer.length > SAMPLE_DATA_BYTES * 2) {
						dobj.addEventListener(Event.ENTER_FRAME, enterFrameHandler);
						paused = true;
						ret = false;
					} else {
						_mpegFrame = new MPEGFrame();
						readFunc = readFrameHeader;
						ret = true;
					}
				}
			} else {
				read = readTmp;
				ret = false;
			}
			return ret;
		}
		
		protected function readMetaDataSize():Boolean {
			var ret:Boolean = true;
			if (stream.bytesAvailable >= 1) {
				read = 0;
				_icyMetaSize = (stream.readUnsignedByte() << 4);
				_metaDataBytesLoaded += _icyMetaSize + 1;
				_metaDataLoaded++;
				if (_icyMetaSize > 0) {
					readFunc = readMetaData;
				} else {
					dispatchEvent(new ICYMetaDataEvent(ICYMetaDataEvent.METADATA));
					readFunc = readFuncContinue;
				}
			} else {
				ret = false;
			}
			return ret;
		}
			
		protected function readMetaData():Boolean {
			var ret:Boolean = true;
			if (stream.bytesAvailable >= _icyMetaSize) {
				/*
				if (_icyMetaSize > 250) {
					trace(mpegFrame);
					throw(new Error("BOOM"));
				}
				*/
				read = 0;
				meta = stream.readUTFBytes(_icyMetaSize);
				dispatchEvent(new ICYMetaDataEvent(ICYMetaDataEvent.METADATA, meta));
				readFunc = readFuncContinue;
			} else {
				ret = false;
			}
			return ret;
		}

		protected function enterFrameHandler(e:Event):void {
			dobj.removeEventListener(Event.ENTER_FRAME, enterFrameHandler);
			resume();
		}
		
		CONFIG::AIR {
			protected function processResponseHeaders(headers:Array):void {
				for (var i:uint = 0; i < headers.length; i++) {
					var header:URLRequestHeader = headers[i] as URLRequestHeader;
					if (header) {
						switch(header.name.toLowerCase()) {
							case "icy-metaint": _icyMetaInterval = parseInt(header.value); break;
							case "icy-name": _icyName = header.value; break;
							case "icy-description": _icyDescription = header.value; break;
							case "icy-url": _icyUrl = header.value; break;
							case "icy-genre": _icyGenre = header.value; break;
							case "icy-br": _icyBitrate = parseInt(header.value); break;
							case "icy-pub": _icyPublish = (header.value == "1"); break;
							case "server": _icyServer = header.value; break;
						}
					}
				}
			}
		}
		
		protected function defaultHandler(e:Event):void {
			dispatchEvent(e.clone());
		}

		public  function hexDump(ba:ByteArray, start:uint, length:uint):String {
			var deb:String = "";
			var debHex:String = "";
			var debAscii:String = "";
			for (var i:int = 0; i < length; i++) {
				if (i % 16 == 0) {
					deb += debHex + debAscii + "\n";
					debHex = debAscii = "";
				}
				var byte:uint = ba[start + i];
				debHex += StringUtils.printf("%02X ", byte);
				debAscii += (byte >= 0x20 && byte < 128) ? String.fromCharCode(byte) : ".";
			}
			if (debHex != "") {
				var fill:uint = Math.floor(length % 16);
				if (fill > 0) {
					for (var j:int = 0; j < 16 - fill; j++) {
						debHex += "   ";
					}
				}
				deb += debHex + debAscii;
			}
			return deb;
		}
	}
}
