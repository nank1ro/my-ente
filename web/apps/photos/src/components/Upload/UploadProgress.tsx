import { type UploadPhase } from "@/new/photos/services/upload/types";
import { useAppContext } from "@/new/photos/types/context";
import { Paper, Snackbar } from "@mui/material";
import { t } from "i18next";
import { useEffect, useState } from "react";
import type {
    InProgressUpload,
    SegregatedFinishedUploads,
    UploadCounter,
    UploadFileNames,
} from "services/upload/uploadManager";
import UploadProgressContext from "./UploadProgress/context";
import { UploadProgressDialog } from "./UploadProgress/dialog";
import { UploadProgressHeader } from "./UploadProgress/header";

interface UploadProgressProps {
    open: boolean;
    onClose: () => void;
    uploadCounter: UploadCounter;
    uploadPhase: UploadPhase;
    percentComplete: number;
    retryFailed: () => void;
    inProgressUploads: InProgressUpload[];
    uploadFileNames: UploadFileNames;
    finishedUploads: SegregatedFinishedUploads;
    hasLivePhotos: boolean;
    cancelUploads: () => void;
}

export const UploadProgress: React.FC<UploadProgressProps> = ({
    open,
    onClose,
    uploadCounter,
    uploadPhase,
    percentComplete,
    retryFailed,
    uploadFileNames,
    hasLivePhotos,
    inProgressUploads,
    finishedUploads,
    cancelUploads,
}) => {
    const { showMiniDialog } = useAppContext();
    const [expanded, setExpanded] = useState(false);

    useEffect(() => {
        if (open) setExpanded(false);
    }, [open]);

    const handleClose = () => {
        if (uploadPhase == "done") {
            onClose();
        } else {
            showMiniDialog({
                title: t("stop_uploads_title"),
                message: t("stop_uploads_message"),
                continue: {
                    text: t("yes_stop_uploads"),
                    color: "critical",
                    action: cancelUploads,
                },
                cancel: t("no"),
            });
        }
    };

    if (!open) {
        return <></>;
    }

    return (
        <UploadProgressContext.Provider
            value={{
                open,
                onClose: handleClose,
                uploadCounter,
                uploadPhase,
                percentComplete,
                retryFailed,
                inProgressUploads,
                uploadFileNames,
                finishedUploads,
                hasLivePhotos,
                expanded,
                setExpanded,
            }}
        >
            {expanded ? <UploadProgressDialog /> : <MinimizedUploadProgress />}
        </UploadProgressContext.Provider>
    );
};

const MinimizedUploadProgress: React.FC = () => (
    <Snackbar open anchorOrigin={{ horizontal: "right", vertical: "bottom" }}>
        <Paper sx={{ width: "min(360px, 100svw)" }}>
            <UploadProgressHeader />
        </Paper>
    </Snackbar>
);
