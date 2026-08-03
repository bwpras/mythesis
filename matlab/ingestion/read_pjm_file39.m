function [GPS_lat,GPS_lon, speed, count, rpm, Ibatt, Vbatt, Payload, Timestamp] = read_pjm_file39(filename)
    % Robust PJM reader for 38B and 39B message formats
    %   - 38B: timestamp = cols 31–38
    %   - 39B: trailer 0D 0A + filler col 31 + timestamp = cols 32–39
    % Filters timestamps to [2025–2030]

    minDate = datetime(2025,1,1);
    maxDate = datetime(2030,1,1);

    GPS_lat=[]; GPS_lon=[]; speed=[];
    rpm=[]; Ibatt=[]; Vbatt=[]; Payload={}; Timestamp=datetime.empty;
    counter=[]; count=0;

    packet_ok=0; packet_bad=0; packet_trunc=0;

    fid=fopen(filename,'rb'); 
    if fid==-1, error('Cannot open file'); end
    cleaner=onCleanup(@() fclose(fid));

    fseek(fid,0,'eof'); fileSize=ftell(fid); fseek(fid,0,'bof');

    while ~feof(fid)
        pos=ftell(fid);

        % --- floats (12B) ---
        floatData=fread(fid,3,'float32');
        if numel(floatData)<3
            fprintf('EOF/truncated floats at byte %d\n',pos);
            break
        end

        % --- start+header (2B) ---
        startByte=fread(fid,1,'uint8');
        header=fread(fid,1,'uint8');
        if numel(startByte)<1 || numel(header)<1
            fprintf('EOF/truncated header at byte %d\n',pos+12);
            break
        end
        if startByte~=33 || header~=14
            fprintf('Bad start/header at byte %d (got %02X %02X)\n',pos+12,startByte,header);
            fseek(fid,pos+1,'bof'); % resync
            packet_bad=packet_bad+1;
            continue
        end

        % --- payload (14B) ---
        dataPayload=fread(fid,14,'uint8');
        if numel(dataPayload)<14
            fprintf('Truncated payload at byte %d\n',pos+14);
            packet_trunc=packet_trunc+1;
            break
        end

        % --- trailer (2B, always 0D 0A) ---
        trailer=fread(fid,2,'uint8');
        if numel(trailer)<2
            fprintf('Truncated trailer at byte %d\n',pos+28);
            packet_trunc=packet_trunc+1;
            break
        end
        if ~(trailer(1)==13 && trailer(2)==10)
            fprintf('Bad trailer at byte %d (%02X %02X)\n',pos+28,trailer(1),trailer(2));
            packet_bad=packet_bad+1;
            continue
        end

        % Peek next 8 bytes (possible 38B timestamp)
        pos_after_trailer = ftell(fid);
        [peek_bytes,n] = fread(fid,8,'uint8=>uint8');

        if n<8
            fprintf('Truncated timestamp at byte %d\n',pos_after_trailer);
            packet_trunc = packet_trunc+1;
            break
        end

        % Try 38B interpretation (cols 31–38)
        ts_raw38 = typecast(peek_bytes,'uint64');
        ts38 = datetime(double(ts_raw38)/1000,'ConvertFrom','posixtime');

        if ts38 >= minDate && ts38 <= maxDate
            % Valid → accept as 38B
            ts_bytes = peek_bytes;
            ts = ts38;
        else
            % Not valid → rewind and treat as 39B (skip filler col 31, use cols 32–39)
            fseek(fid,pos_after_trailer+1,'bof');  % skip filler
            [ts_bytes,n] = fread(fid,8,'uint8=>uint8');
            if n<8
                fprintf('Truncated 39B timestamp at byte %d\n',ftell(fid));
                packet_trunc = packet_trunc+1;
                break
            end
            ts_raw = typecast(ts_bytes,'uint64');
            ts = datetime(double(ts_raw)/1000,'ConvertFrom','posixtime');
        end

        % Debug print
        % fprintf('Timestamp raw bytes: %s -> %s\n',...
        %     sprintf('%02X ',ts_bytes), string(ts));

        % --- decode payload fields ---
        cnt=typecast(uint8(dataPayload(1:8)),'uint64');
        rp=double(typecast(uint8(dataPayload(9:10)),'uint16'))/10;
        ib=double(typecast(uint8(dataPayload(11:12)),'uint16'))/1000;
        vb=double(typecast(uint8(dataPayload(13:14)),'uint16'))/100;

        % --- timestamp filter ---
        if ts<minDate || ts>maxDate
            %fprintf('Skipping out-of-range ts at byte %d (%s)\n',pos,string(ts));
            continue
        end

        % --- append ---
        count=count+1;
        GPS_lat(count)=floatData(1);
        GPS_lon(count)=floatData(2);
        speed(count)=floatData(3);
        counter(count)=cnt;
        rpm(count)=rp; Ibatt(count)=ib; Vbatt(count)=vb;
        Payload{count}=dataPayload;
        Timestamp(count,1)=ts;

        packet_ok=packet_ok+1;

        if mod(count,1000)==0
            fprintf('Read %d packets (%.1f%% of file)\n',count,100*ftell(fid)/fileSize);
        end
    end

    fprintf('\n=== Summary ===\n');
    fprintf('Good packets: %d\n',packet_ok);
    fprintf('Bad headers : %d\n',packet_bad);
    fprintf('Truncated   : %d\n',packet_trunc);
    fprintf('Total parsed: %d\n',count);
end
