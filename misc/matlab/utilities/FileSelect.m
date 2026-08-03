clc
clear
close all

% ------------------------------------------------------------
% Select & Copy Files in a Time Range (by filename prefix)
% ------------------------------------------------------------

srcFolder = uigetdir(pwd, 'Select source folder with .bin files');
if srcFolder == 0
    error('No source folder selected.');
end

dstFolder = uigetdir(pwd, 'Select destination folder');
if dstFolder == 0
    error('No destination folder selected.');
end

% List all .bin files
files = dir(fullfile(srcFolder, '*.bin'));

% Time range (prefix comparison, as STRING)
startTag = "2025_110514";   % from 23 Oct, 07h
endTag   = "2025_110523";   % to   23 Oct, 15h

fprintf('Filtering files between %s and %s\n', startTag, endTag);

for i = 1:numel(files)
    fname = files(i).name;

    % We need at least '2025_MMDDHH' → 5 + 6 = 11 chars
    if numel(fname) < 11
        continue;
    end

    % Extract 'YYYY_MMDDHH' from filename
    prefix = string(fname(1:11));   % e.g. "2025_080808"

    % Lexicographic comparison on string scalars
    if prefix >= startTag && prefix <= endTag

        src = fullfile(srcFolder, fname);
        dst = fullfile(dstFolder, fname);

        copyfile(src, dst);

        fprintf('Copied: %s (prefix = %s)\n', fname, prefix);
    end
end

fprintf('Done.\n');
