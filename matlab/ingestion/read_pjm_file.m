
function [GPS_lat,GPS_lon, speed, count, rpm,Ibatt,Vbatt, Payload, Timestamp] = read_pjm_file(filename)
    % Inizializzazione delle variabili di output
    GPS_lat = [];
    GPS_lon = [];
    speed = [];
    counter = [];
    rpm = [];
    Ibatt = [];
    Vbatt = [];
    Payload = {};   
    Timestamp = datetime.empty;
    
    count = 0;
    n_byte = 0;
    fid = fopen(filename, 'rb');
    if fid == -1
        error('Impossibile aprire il file.');
    end
   
    while ~feof(fid)
        count = count + 1;
        % Legge i 5 dati float (4 byte ciascuno)
        floatData = fread(fid, 3, 'float32');
        if numel(floatData) < 3
            disp('Manca Intestazione');
            disp(n_byte)
            break; % Fine del file o dati incompleti
        end
        n_byte = n_byte + 3*4;
        
        startByte = fread(fid, 1, 'uint8');
        if isempty(startByte) || startByte ~= 33 % 21
            disp('Byte di inizio messaggio non trovato.');
            disp(n_byte)
            break;
        end
        n_byte = n_byte + 1;

        header = fread(fid, 1, 'uint8');
        if header ~= 14 % 0E=14 in decimal format
            warning('Intestazione incompleto.');
            break;
        end
        n_byte = n_byte + 1;
        
        
        % Legge la parte dati

        dataPayload = fread(fid, 14, 'uint8');
        if numel(dataPayload) < 14
            disp('Dati incompleti.');
            disp(n_byte)
            break;
        
        end
        n_byte = n_byte + 14;
        endByte = fread(fid, 1, 'uint8');
        % Legge il byte finale (deve essere 0x04)
        endByte2 = fread(fid, 1, 'uint8');
        if isempty(endByte2) || endByte2 ~= 10 % 0A=10 in decimal format
            disp('Byte di fine messaggio errato.');
            disp(n_byte)
            break;
        end
        n_byte = n_byte + 2;
        ts_raw = fread(fid, 1, 'uint64');
        ts_converted = datetime(ts_raw / 1000, 'ConvertFrom', 'posixtime');
        ts_converted.Format = 'yyyy-MM-dd HH:mm:ss.SSSSSS';

        Timestamp(count) = ts_converted;
               
        GPS_lat(count) = floatData(1);
        GPS_lon(count) = floatData(2);
        speed(count) = floatData(3);
        b = uint8(dataPayload(1:8));
        counter(count) = typecast([b(1) b(2) b(3) b(4) b(5) b(6) b(7) b(8)], 'uint64');
        c = uint8(dataPayload(9:10));
        rpm(count) = typecast([c(1) c(2)], 'uint16')/10;
        d = uint8(dataPayload(11:12));
        Ibatt(count) = typecast([d(1) d(2)], 'uint16')/1000;
        f = uint8(dataPayload(13:14));
        Vbatt(count) = typecast([f(1) f(2)], 'uint16')/100;

        Payload{count} = dataPayload;
    end
 
    
    fclose(fid);
    
end
