function save_all_figures(outDir)
%SAVE_ALL_FIGURES Save every open figure to PNG (300 dpi), PDF (vector), and FIG.
% Usage:
%   save_all_figures()                  % saves into pwd
%   save_all_figures(fullfile(paths.figures, 'custom')) % custom directory

    if nargin < 1 || isempty(outDir), outDir = pwd; end
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    figs = findall(0,'Type','figure');                       % all (incl. hidden)
    % If you want only visible: figs = get(groot,'Children'); % visible only

    % Sort by figure number for reproducible order
    [~,ord] = sort([figs.Number]);
    figs = figs(ord);

    for f = reshape(figs,1,[])   % row vector loop
        % Derive a safe base name from the figure Name (fallback to Figure_<Number>)
        base = string(f.Name);
        if strlength(base)==0
            base = "Figure_" + f.Number;
        end
        base = regexprep(base, '[^\w\s\-]', '_');  % sanitize filename chars
        base = strtrim(base);
        if strlength(base)==0
            base = "Figure_" + f.Number;
        end

        % Paths
        pngPath = fullfile(outDir, base + ".png");
        pdfPath = fullfile(outDir, base + ".pdf");
        figPath = fullfile(outDir, base + ".fig");

        % Raster image (good for slides / docs)
        exportgraphics(f, pngPath, 'Resolution', 300);

        % Vector PDF (best for publications when possible)
        exportgraphics(f, pdfPath, 'ContentType','vector');

        % Native .fig for reopening/editing in MATLAB later
        savefig(f, figPath);
    end
end
